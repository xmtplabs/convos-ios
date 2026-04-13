import ConvosCore
import CryptoKit
@preconcurrency import Foundation
import Observation
import SwiftUI

enum JoinerPairingFlowState: Equatable {
    case connecting
    case pinEntry(initiatorInboxId: String)
    case waitingForEmoji(emojis: [String])
    case syncing
    case completed
    case failed(String)
    case expired
}

@Observable
@MainActor
final class JoinerPairingSheetViewModel {
    var flowState: JoinerPairingFlowState
    var title: String = "Request to pair"
    var canDismiss: Bool = true
    var secondsRemaining: Int
    var enteredPin: String = ""

    private let pairingId: String
    private let expiresAt: Date
    private let timeoutInterval: TimeInterval
    private let vaultManager: VaultManager?
    private let initiatorName: String?
    private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var notificationObservers: [any NSObjectProtocol] = []
    private var initiatorInboxId: String?

    init(
        pairingId: String,
        expiresAt: Date? = nil,
        initiatorName: String? = nil,
        timeoutInterval: TimeInterval = 60,
        vaultManager: VaultManager? = nil
    ) {
        self.pairingId = pairingId
        self.timeoutInterval = timeoutInterval
        self.initiatorName = initiatorName
        self.vaultManager = vaultManager
        self.expiresAt = expiresAt ?? Date().addingTimeInterval(timeoutInterval)
        self.secondsRemaining = max(0, Int(self.expiresAt.timeIntervalSinceNow))
        self.flowState = .connecting

        observeNotifications()
    }

    deinit {
        let observers = notificationObservers
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observeNotifications() {
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .vaultDidReceiveKeyBundle,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.onPairingCompleted()
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .vaultPairingError,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let message = notification.userInfo?["message"] as? String ?? "Pairing failed"
            Task { @MainActor in
                self.onPairingFailed(message)
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .vaultDidReceivePin,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let pin = notification.userInfo?["pin"] as? String,
                  let senderInboxId = notification.userInfo?["initiatorInboxId"] as? String
            else { return }
            Task { @MainActor in
                self.onPinReceived(pin, from: senderInboxId)
            }
        })
    }

    var initiatorDeviceName: String {
        initiatorName ?? "the other device"
    }

    var formattedPin: String {
        PairingCoordinator.formatPin(enteredPin)
    }

    var isPinComplete: Bool {
        enteredPin.count == 6
    }

    func sendJoinRequest() async {
        guard let vaultManager else { return }

        do {
            try await vaultManager.sendPairingJoinRequest(
                slug: pairingId,
                deviceName: DeviceInfo.deviceName
            )
        } catch {
            flowState = .failed(error.localizedDescription)
        }
    }

    func submitPin() async {
        guard let vaultManager, let initiatorInboxId, isPinComplete else { return }

        do {
            try await vaultManager.sendPinEcho(enteredPin, to: initiatorInboxId)

            countdownTask?.cancel()

            let vaultInboxId = await vaultManager.vaultInboxId ?? ""
            let emojis = PairingCoordinator.emojiFingerprint(
                inboxA: initiatorInboxId,
                inboxB: vaultInboxId,
                pin: enteredPin
            )
            title = "Confirm pairing"
            flowState = .waitingForEmoji(emojis: emojis)
        } catch {
            flowState = .failed(error.localizedDescription)
        }
    }

    func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard let self else { break }

                let remaining = Int(self.expiresAt.timeIntervalSinceNow)
                if remaining <= 0 {
                    self.secondsRemaining = 0
                    self.flowState = .expired
                    break
                }
                self.secondsRemaining = remaining
            }
        }
    }

    private func onPinReceived(_ pin: String, from senderInboxId: String) {
        initiatorInboxId = senderInboxId
        flowState = .pinEntry(initiatorInboxId: senderInboxId)
    }

    func onPairingCompleted() {
        countdownTask?.cancel()
        title = "Syncing"
        flowState = .syncing
        canDismiss = false

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            title = "Device paired"
            flowState = .completed
            canDismiss = true
        }
    }

    func onPairingFailed(_ message: String) {
        flowState = .failed(message)
        canDismiss = true
    }

    func cancel() {
        countdownTask?.cancel()
        Task {
            await vaultManager?.stopJoinerPairing()
        }
    }
}
