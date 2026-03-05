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

    private let vaultManager: VaultManager
    private var coordinator: PairingCoordinator?
    private var joinerDeviceName: String = "New Device"

    init(vaultManager: VaultManager) {
        self.vaultManager = vaultManager
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

        let inviteURL = "https://convos.org/pair/\(UUID().uuidString.prefix(8).lowercased())"

        do {
            try await coordinator.startPairing(inviteURL: inviteURL)
            flowState = .qrCode(url: inviteURL)
        } catch {
            flowState = .failed(error.localizedDescription)
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

        let deviceName = joinerDeviceName
        canDismiss = false
        flowState = .syncing

        do {
            try await coordinator?.confirmPin(enteredPin)
            let state = await coordinator?.currentState
            if case .completed = state {
                title = "Device added"
                flowState = .completed(deviceName: deviceName)
                canDismiss = true
            } else if case let .failed(error) = state {
                flowState = .failed(error.errorDescription ?? "Pairing failed")
                canDismiss = true
            }
        } catch {
            flowState = .failed(error.localizedDescription)
            canDismiss = true
        }
    }

    func cancel() async {
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
