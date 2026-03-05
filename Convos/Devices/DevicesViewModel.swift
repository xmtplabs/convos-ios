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
    }
}
