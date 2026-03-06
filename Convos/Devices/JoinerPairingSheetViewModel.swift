import ConvosCore
import Observation
import SwiftUI

enum JoinerPairingFlowState: Equatable {
    case showingPin(pin: String, expiresAt: Date)
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

    private let pairingId: String
    private let pin: String
    private let expiresAt: Date
    private let timeoutInterval: TimeInterval
    private let vaultManager: VaultManager?
    private var countdownTask: Task<Void, Never>?
    private nonisolated(unsafe) var keyBundleObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var pairingErrorObserver: (any NSObjectProtocol)?

    private let initiatorName: String?

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
        self.pin = PairingCoordinator.generatePin()
        self.expiresAt = expiresAt ?? Date().addingTimeInterval(timeoutInterval)
        self.secondsRemaining = max(0, Int(self.expiresAt.timeIntervalSinceNow))
        self.flowState = .showingPin(pin: pin, expiresAt: self.expiresAt)

        observeNotifications()
    }

    deinit {
        if let keyBundleObserver {
            NotificationCenter.default.removeObserver(keyBundleObserver)
        }
        if let pairingErrorObserver {
            NotificationCenter.default.removeObserver(pairingErrorObserver)
        }
    }

    private func observeNotifications() {
        keyBundleObserver = NotificationCenter.default.addObserver(
            forName: .vaultDidReceiveKeyBundle,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.onPairingCompleted()
            }
        }

        pairingErrorObserver = NotificationCenter.default.addObserver(
            forName: .vaultPairingError,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let message = notification.userInfo?["message"] as? String ?? "Pairing failed"
            Task { @MainActor in
                self.onPairingFailed(message)
            }
        }
    }

    var formattedPin: String {
        PairingCoordinator.formatPin(pin)
    }

    var initiatorDeviceName: String {
        initiatorName ?? "the other device"
    }

    func sendJoinRequest() async {
        guard let vaultManager else { return }

        do {
            try await vaultManager.sendPairingJoinRequest(
                slug: pairingId,
                pin: pin,
                deviceName: DeviceInfo.deviceName
            )
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
