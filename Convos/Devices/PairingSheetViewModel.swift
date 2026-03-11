import ConvosCore
import Observation
import SwiftUI

enum PairingFlowState: Equatable {
    case qrCode(url: String)
    case showingPin(pin: String, deviceName: String)
    case emojiConfirmation(emojis: [String], deviceName: String)
    case syncing
    case completed(deviceName: String)
    case failed(String)
    case expired
}

@Observable
@MainActor
final class PairingSheetViewModel {
    var flowState: PairingFlowState = .qrCode(url: "")
    var canDismiss: Bool = true
    var title: String = "Pair new device"
    var secondsRemaining: Int = 60

    private let vaultManager: VaultManager
    private let timeoutInterval: TimeInterval
    private(set) var coordinator: PairingCoordinator?
    private var joinerDeviceName: String = "New Device"
    private var joinerInboxId: String?
    private var expiresAt: Date = .distantFuture
    private var countdownTask: Task<Void, Never>?

    init(vaultManager: VaultManager, timeoutInterval: TimeInterval = 120) {
        self.vaultManager = vaultManager
        self.timeoutInterval = timeoutInterval
        self.secondsRemaining = Int(timeoutInterval)
    }

    func startPairing() async {
        let coordinator = PairingCoordinator(vaultManager: vaultManager, timeoutInterval: timeoutInterval)
        self.coordinator = coordinator

        expiresAt = Date().addingTimeInterval(timeoutInterval)
        let expiresAtUnix = Int(expiresAt.timeIntervalSince1970)

        do {
            let slug = try await vaultManager.createPairingInvite(expiresAt: expiresAt)
            let vaultInboxId = await vaultManager.vaultInboxId ?? ""

            let domain = ConfigManager.shared.associatedDomain
            let encodedName = DeviceInfo.deviceName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let inviteURL = "https://\(domain)/pair/\(slug)?expires=\(expiresAtUnix)&name=\(encodedName)"

            try await coordinator.startPairing(inviteURL: inviteURL, initiatorInboxId: vaultInboxId)
            QAEvent.emit(.vault, "pairing_url_created", ["url": inviteURL])
            secondsRemaining = Int(timeoutInterval)
            flowState = .qrCode(url: inviteURL)
            startCountdown()
        } catch {
            Log.error("Pairing start failed: \(error)")
            flowState = .failed(error.localizedDescription)
        }
    }

    private func startCountdown() {
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

    func onJoinRequestReceived(deviceName: String, joinerInboxId: String) async {
        guard let coordinator else { return }

        joinerDeviceName = deviceName
        self.joinerInboxId = joinerInboxId
        do {
            try await coordinator.receivedJoinRequest(joinerInboxId: joinerInboxId, deviceName: deviceName)
            let state = await coordinator.currentState
            if case let .showingPin(pin, _, _) = state {
                try await vaultManager.sendPinToJoiner(pin, joinerInboxId: joinerInboxId)
                flowState = .showingPin(pin: pin, deviceName: deviceName)
            }
        } catch {
            Log.error("Pairing join request failed: \(error)")
            flowState = .failed(error.localizedDescription)
        }
    }

    func onPinEchoReceived(pin: String, from senderInboxId: String) async {
        guard let coordinator else { return }

        do {
            try await coordinator.receivedPinEcho(pin, from: senderInboxId)
            let state = await coordinator.currentState
            if case let .waitingForEmojiConfirmation(emojis, _) = state {
                title = "Confirm pairing"
                flowState = .emojiConfirmation(emojis: emojis, deviceName: joinerDeviceName)
            }
        } catch {
            Log.error("Pairing pin echo failed: \(error)")
            flowState = .failed(error.localizedDescription)
        }
    }

    func confirmEmoji() async {
        guard let coordinator else { return }

        countdownTask?.cancel()
        let deviceName = joinerDeviceName
        canDismiss = false
        flowState = .syncing

        do {
            try await coordinator.confirmEmoji()
            let state = await coordinator.currentState
            if case .completed = state {
                await vaultManager.stopPairing()
                title = "Device added"
                flowState = .completed(deviceName: deviceName)
                canDismiss = true
            } else if case let .failed(error) = state {
                await vaultManager.stopPairing()
                flowState = .failed(error.errorDescription ?? "Pairing failed")
                canDismiss = true
            }
        } catch {
            Log.error("Pairing emoji confirm failed: \(error)")
            await vaultManager.stopPairing()
            flowState = .failed(error.localizedDescription)
            canDismiss = true
        }
    }

    func cancel() async {
        countdownTask?.cancel()
        if let coordinator, let joinerInboxId {
            let state = await coordinator.currentState
            if case .showingPin = state {
                await vaultManager.sendPairingError(to: joinerInboxId, message: "Pairing was cancelled by the other device")
            } else if case .waitingForEmojiConfirmation = state {
                await vaultManager.sendPairingError(to: joinerInboxId, message: "Pairing was cancelled by the other device")
            }
        }
        await vaultManager.stopPairing()
        await coordinator?.cancel()
        coordinator = nil
    }

    func triggerConfirmEmoji() {
        Task { await confirmEmoji() }
    }

    func triggerCancel() {
        Task { await cancel() }
    }
}
