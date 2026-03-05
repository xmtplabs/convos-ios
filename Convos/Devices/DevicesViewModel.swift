import ConvosCore
import Observation
import SwiftUI

@Observable
@MainActor
final class DevicesViewModel {
    var devices: [VaultDevice] = []
    var isLoading: Bool = false
    var showPairingSheet: Bool = false
    var pairingViewModel: PairingSheetViewModel?

    private let session: any SessionManagerProtocol
    private var delegateBridge: VaultManagerDelegateBridge?

    init(session: any SessionManagerProtocol) {
        self.session = session
    }

    func loadDevices() async {
        isLoading = true
        defer { isLoading = false }

        guard let vaultService = session.vaultService,
              let vaultManager = vaultService as? VaultManager
        else {
            devices = [
                VaultDevice(
                    inboxId: "self",
                    name: DeviceInfo.deviceName,
                    isCurrentDevice: true
                ),
            ]
            return
        }

        do {
            devices = try await vaultManager.listDevices()
        } catch {
            devices = [
                VaultDevice(
                    inboxId: "self",
                    name: DeviceInfo.deviceName,
                    isCurrentDevice: true
                ),
            ]
        }
    }

    func startPairing() {
        let vaultManager: VaultManager
        if let service = session.vaultService as? VaultManager {
            vaultManager = service
        } else {
            vaultManager = .preview
        }

        let vm = PairingSheetViewModel(vaultManager: vaultManager)
        pairingViewModel = vm
        showPairingSheet = true

        let bridge = VaultManagerDelegateBridge { [weak vm] request in
            Task { @MainActor in
                await vm?.onJoinRequestReceived(
                    pin: request.pin,
                    deviceName: request.deviceName,
                    joinerInboxId: request.joinerInboxId
                )
            }
        }
        delegateBridge = bridge
        Task { await vaultManager.setDelegate(bridge) }
    }

    func stopPairing() {
        guard let vaultManager = session.vaultService as? VaultManager else { return }
        Task { await vaultManager.stopPairingListener() }
        delegateBridge = nil
    }
}

private final class VaultManagerDelegateBridge: VaultManagerDelegate, Sendable {
    private let onJoinRequest: @Sendable (PairingJoinRequest) -> Void

    init(onJoinRequest: @escaping @Sendable (PairingJoinRequest) -> Void) {
        self.onJoinRequest = onJoinRequest
    }

    func vaultManager(_ manager: VaultManager, didReceivePairingJoinRequest request: PairingJoinRequest) {
        onJoinRequest(request)
    }
}
