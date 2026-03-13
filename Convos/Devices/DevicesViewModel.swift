import Combine
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
    var devicePendingRemoval: VaultDevice?
    var isRemovingDevice: Bool = false

    var showRemoveDeviceSheet: Bool {
        get { devicePendingRemoval != nil }
        set { if !newValue { devicePendingRemoval = nil } }
    }

    private let session: any SessionManagerProtocol
    private var delegateBridge: VaultManagerDelegateBridge?
    private var devicesCancellable: AnyCancellable?

    init(session: any SessionManagerProtocol) {
        self.session = session
    }

    func startObserving() {
        let repository = VaultDeviceRepository(dbReader: session.databaseReader)
        devicesCancellable = repository.devicesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dbDevices in
                guard let self else { return }
                if dbDevices.isEmpty {
                    self.devices = [
                        VaultDevice(
                            inboxId: "self",
                            name: DeviceInfo.deviceName,
                            isCurrentDevice: true
                        ),
                    ]
                } else {
                    self.devices = dbDevices.map {
                        VaultDevice(inboxId: $0.inboxId, name: $0.name, isCurrentDevice: $0.isCurrentDevice)
                    }
                }
            }
    }

    func confirmRemoveDevice() {
        guard let device = devicePendingRemoval else { return }
        isRemovingDevice = true

        Task {
            defer {
                isRemovingDevice = false
                devicePendingRemoval = nil
            }

            guard let vaultManager = session.vaultService as? VaultManager else { return }

            do {
                try await vaultManager.removeDevice(inboxId: device.inboxId)
            } catch {
                Log.error("Failed to remove device: \(error)")
            }
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

        let bridge = VaultManagerDelegateBridge(
            onJoinRequest: { [weak vm] request in
                Task { @MainActor in
                    await vm?.onJoinRequestReceived(
                        deviceName: request.deviceName,
                        joinerInboxId: request.joinerInboxId
                    )
                }
            },
            onPinEcho: { [weak vm] pin, joinerInboxId in
                Task { @MainActor in
                    await vm?.onPinEchoReceived(pin: pin, from: joinerInboxId)
                }
            }
        )
        delegateBridge = bridge
        Task { await vaultManager.setDelegate(bridge) }
    }

    func stopPairing() {
        guard let vaultManager = session.vaultService as? VaultManager else { return }
        Task { await vaultManager.stopPairing() }
        delegateBridge = nil
    }
}

private final class VaultManagerDelegateBridge: VaultManagerDelegate, Sendable {
    private let onJoinRequest: @Sendable (PairingJoinRequest) -> Void
    private let onPinEcho: @Sendable (String, String) -> Void

    init(
        onJoinRequest: @escaping @Sendable (PairingJoinRequest) -> Void,
        onPinEcho: @escaping @Sendable (String, String) -> Void
    ) {
        self.onJoinRequest = onJoinRequest
        self.onPinEcho = onPinEcho
    }

    func vaultManager(_ manager: VaultManager, didReceivePairingJoinRequest request: PairingJoinRequest) {
        onJoinRequest(request)
    }

    func vaultManager(_ manager: VaultManager, didReceivePinEcho pin: String, from joinerInboxId: String) {
        onPinEcho(pin, joinerInboxId)
    }
}
