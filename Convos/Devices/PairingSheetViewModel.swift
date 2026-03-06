import ConvosCore
import Observation
import SwiftUI

enum PairingFlowState: Equatable {
    case qrCode(url: String)
    case pinEntry(deviceName: String)
    case syncing
    case completed(deviceName: String)
    case failed(String)
    case expired
}

@Observable
@MainActor
final class PairingSheetViewModel {
    var flowState: PairingFlowState = .qrCode(url: "")
    var enteredPin: String = ""
    var canDismiss: Bool = true
    var title: String = "Pair new device"
    var secondsRemaining: Int = 60

    private let vaultManager: VaultManager
    private let timeoutInterval: TimeInterval
    private var coordinator: PairingCoordinator?
    private var joinerDeviceName: String = "New Device"
    private var expiresAt: Date = .distantFuture
    private var countdownTask: Task<Void, Never>?

    init(vaultManager: VaultManager, timeoutInterval: TimeInterval = 120) {
        self.vaultManager = vaultManager
        self.timeoutInterval = timeoutInterval
        self.secondsRemaining = Int(timeoutInterval)
    }

    var isApproveEnabled: Bool {
        if case .pinEntry = flowState {
            return enteredPin.filter(\.isNumber).count == 6
        }
        return false
    }

    func startPairing() async {
        let coordinator = PairingCoordinator(vaultManager: vaultManager)
        self.coordinator = coordinator

        expiresAt = Date().addingTimeInterval(timeoutInterval)
        let expiresAtUnix = Int(expiresAt.timeIntervalSince1970)

        do {
            let slug = try await vaultManager.createPairingInvite(expiresAt: expiresAt)

            let domain = ConfigManager.shared.associatedDomain
            let inviteURL = "https://\(domain)/pair/\(slug)?expires=\(expiresAtUnix)"

            try await coordinator.startPairing(inviteURL: inviteURL)
            secondsRemaining = Int(timeoutInterval)
            flowState = .qrCode(url: inviteURL)
            startCountdown()
        } catch {
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

    func onJoinRequestReceived(pin: String, deviceName: String, joinerInboxId: String) async {
        guard let coordinator else { return }

        joinerDeviceName = deviceName
        do {
            try await coordinator.receivedJoinRequest(pin: pin, joinerInboxId: joinerInboxId)
            flowState = .pinEntry(deviceName: deviceName)
        } catch {
            flowState = .failed(error.localizedDescription)
        }
    }

    func approve() async {
        guard coordinator != nil else { return }

        countdownTask?.cancel()
        let deviceName = joinerDeviceName
        canDismiss = false
        flowState = .syncing

        do {
            try await coordinator?.confirmPin(enteredPin)
            let state = await coordinator?.currentState
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
        } catch let error as PairingError where error == .invalidConfirmationCode {
            flowState = .failed(error.localizedDescription)
            canDismiss = true
        } catch {
            await vaultManager.stopPairing()
            flowState = .failed(error.localizedDescription)
            canDismiss = true
        }
    }

    func cancel() async {
        countdownTask?.cancel()
        if let coordinator, case let .waitingForConfirmation(_, joinerInboxId) = await coordinator.currentState {
            await vaultManager.sendPairingError(to: joinerInboxId, message: "Pairing was cancelled by the other device")
        }
        await vaultManager.stopPairing()
        await coordinator?.cancel()
        coordinator = nil
    }

    func triggerApprove() {
        Task { await approve() }
    }

    func triggerCancel() {
        Task { await cancel() }
    }
}
