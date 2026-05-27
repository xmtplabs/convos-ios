import ConvosCore
import Observation
import SwiftUI

struct PairedDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isCurrentDevice: Bool
    let createdAt: Date?
    /// True for rows the UI inserts before the network surfaces the real
    /// installation, so the user sees the just-paired device instantly on
    /// dismissing the pairing sheet. Reconciled (removed) on the first
    /// snapshot that includes a real non-self installation.
    let isOptimistic: Bool

    init(id: String, name: String, isCurrentDevice: Bool, createdAt: Date?, isOptimistic: Bool = false) {
        self.id = id
        self.name = name
        self.isCurrentDevice = isCurrentDevice
        self.createdAt = createdAt
        self.isOptimistic = isOptimistic
    }
}

@Observable
@MainActor
final class DevicesViewModel {
    var devices: [PairedDevice] = []
    var isLoading: Bool = false
    var showPairingSheet: Bool = false
    var pairingViewModel: PairingSheetViewModel?
    var devicePendingRemoval: PairedDevice?
    var isRemovingDevice: Bool = false
    var lastErrorMessage: String?

    var showRemoveDeviceSheet: Bool {
        get { devicePendingRemoval != nil }
        set { if !newValue { devicePendingRemoval = nil } }
    }

    private let pairingServiceFactory: @MainActor () -> any PairingServiceProtocol
    private let session: (any SessionManagerProtocol)?
    private let appGroupIdentifier: String?
    @ObservationIgnored
    private let observers: PairingNotificationObservers = .init()
    @ObservationIgnored
    private var didStartObserving: Bool = false

    /// `pairingServiceFactory` returns a fresh initiator-side `PairingService`
    /// every time the user taps "Add new device".
    ///
    /// `session` is the live session, used to query the inbox's libxmtp
    /// installations and to revoke them. Optional so previews / tests can
    /// pass nil and rely on `devices` being set directly.
    ///
    /// `appGroupIdentifier` keys access into `PairedDeviceNameStore` (the
    /// post-pair name map). Optional so previews work.
    init(
        pairingServiceFactory: @escaping @MainActor () -> any PairingServiceProtocol,
        session: (any SessionManagerProtocol)? = nil,
        appGroupIdentifier: String? = nil
    ) {
        self.pairingServiceFactory = pairingServiceFactory
        self.session = session
        self.appGroupIdentifier = appGroupIdentifier
        self.devices = [
            PairedDevice(
                id: "self",
                name: DeviceInfo.deviceName,
                isCurrentDevice: true,
                createdAt: nil
            ),
        ]
    }

    func startObserving() {
        if !didStartObserving {
            didStartObserving = true
            observers.add(for: .pairingDidCompleteSuccessfully) { [weak self] notification in
                // Only the initiator-side post carries `joinerDeviceName`
                // (`PairingSheetViewModel.confirmEmoji`). The joiner's
                // post has no userInfo. We use that to gate the
                // initiator-only profile-snapshot broadcast: the joiner
                // is the one *receiving* the snapshots, it shouldn't
                // re-send them.
                let userInfo = notification.userInfo
                let joinerDeviceName = userInfo?["joinerDeviceName"] as? String
                let displayName = joinerDeviceName ?? "New device"
                let isInitiatorSide = joinerDeviceName != nil
                Task { @MainActor in
                    self?.insertOptimisticDevice(named: displayName)
                    await self?.refreshUntilRealInstallationAppears()
                    if isInitiatorSide {
                        await self?.broadcastProfileSnapshotsAfterPair()
                    }
                }
            }
        }
        Task { @MainActor in
            await refreshInstallations(refreshFromNetwork: true)
        }
    }

    /// Initiator-only: once the joiner's installation is visible in our
    /// inbox, broadcast a fresh `ProfileSnapshot` to every group so the
    /// joiner's new local DB hydrates each conversation's members
    /// immediately. Falls through silently if the joiner's installation
    /// never appears within the broadcaster's polling window.
    private func broadcastProfileSnapshotsAfterPair() async {
        guard let session else { return }
        let broadcaster = PostPairProfileSnapshotBroadcaster(
            messagingService: session.messagingService()
        )
        _ = await broadcaster.runAfterPairing()
    }

    /// Inserts a non-self placeholder row with the just-paired device's
    /// name so the user sees the row the instant they dismiss the
    /// pairing sheet. Replaced by the real installation row on the next
    /// `refreshInstallations` that finds a non-self installation in
    /// the snapshot.
    private func insertOptimisticDevice(named deviceName: String) {
        // If a real non-self installation already exists in the list,
        // no need for an optimistic row.
        if devices.contains(where: { !$0.isCurrentDevice && !$0.isOptimistic }) { return }
        // De-dupe optimistic rows in case the notification fires twice.
        devices.removeAll { $0.isOptimistic }
        devices.append(
            PairedDevice(
                id: "optimistic-\(UUID().uuidString)",
                name: deviceName,
                isCurrentDevice: false,
                createdAt: Date(),
                isOptimistic: true
            )
        )
    }

    /// After a successful pair we want to reconcile the optimistic row
    /// against the actual installation set. libxmtp's
    /// `listInstallations(refreshFromNetwork: true)` reflects
    /// network-side state that lags the joiner's key-package publish by
    /// a few seconds. Poll until a real non-self installation shows or
    /// we hit the cap.
    private func refreshUntilRealInstallationAppears() async {
        let schedule: [TimeInterval] = [0, 2, 5, 10, 20]
        for (index, delay) in schedule.enumerated() {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            await refreshInstallations(refreshFromNetwork: true)
            if devices.contains(where: { !$0.isCurrentDevice && !$0.isOptimistic }) {
                Log.info("DevicesViewModel: paired device appeared after \(delay)s (attempt \(index + 1))")
                return
            }
        }
        Log.warning("DevicesViewModel: paired device did not appear in network state after \(schedule.last ?? 0)s")
    }

    func refreshInstallations(refreshFromNetwork: Bool) async {
        guard let session else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await session.messagingService()
                .installationsSnapshot(refreshFromNetwork: refreshFromNetwork)
            let currentId = snapshot.currentInstallationId
            let currentName = DeviceInfo.deviceName

            // Consume the post-pair pending name and claim it for the
            // first non-self installation that doesn't yet have one.
            // Order matters: only consume if we have a target to assign
            // to. The poll loop fires `refreshInstallations` multiple
            // times after `.pairingDidCompleteSuccessfully`; consuming
            // on the first pass (before the network surfaces the new
            // installation) would burn the pending name and leave the
            // row labelled with the "Device <hex>" fallback forever.
            if let appGroupIdentifier {
                let unnamedNonSelf = snapshot.installations
                    .first { installation in
                        installation.id != currentId
                            && PairedDeviceNameStore.name(forInstallationId: installation.id, appGroup: appGroupIdentifier) == nil
                    }
                if let target = unnamedNonSelf,
                   let pendingName = PairedDeviceNameStore.consumePending(appGroup: appGroupIdentifier) {
                    PairedDeviceNameStore.setName(pendingName, forInstallationId: target.id, appGroup: appGroupIdentifier)
                }
            }

            var assembled: [PairedDevice] = snapshot.installations.map { info in
                let isCurrent = info.id == currentId
                let resolvedName: String
                if isCurrent {
                    resolvedName = currentName
                } else if let appGroupIdentifier,
                          let persisted = PairedDeviceNameStore.name(forInstallationId: info.id, appGroup: appGroupIdentifier) {
                    resolvedName = persisted
                } else {
                    resolvedName = Self.shortDeviceName(installationId: info.id)
                }
                return PairedDevice(
                    id: info.id,
                    name: resolvedName,
                    isCurrentDevice: isCurrent,
                    createdAt: info.createdAt
                )
            }
            if !assembled.contains(where: { $0.isCurrentDevice }) {
                assembled.insert(
                    PairedDevice(id: currentId, name: currentName, isCurrentDevice: true, createdAt: nil),
                    at: 0
                )
            }
            // Preserve the optimistic row only while the snapshot still
            // shows just this device — i.e. the network hasn't yet
            // surfaced the freshly-paired installation. Drop it as soon
            // as a real non-self installation appears so we don't double-
            // count.
            let hasRealNonSelf = assembled.contains { !$0.isCurrentDevice }
            if !hasRealNonSelf {
                let existingOptimistic = devices.filter { $0.isOptimistic }
                assembled.append(contentsOf: existingOptimistic)
            }
            devices = assembled
        } catch {
            Log.warning("DevicesViewModel: failed to refresh installations: \(error)")
        }
    }

    func confirmRemoveDevice() {
        guard let device = devicePendingRemoval, let session else { return }
        isRemovingDevice = true
        // Clear any prior failure before retrying, so a successful retry
        // doesn't leave a stale "Couldn't remove the device" banner up.
        lastErrorMessage = nil

        Task { @MainActor in
            defer {
                isRemovingDevice = false
                devicePendingRemoval = nil
            }
            do {
                try await session.messagingService().revokeInstallation(installationId: device.id)
                await refreshInstallations(refreshFromNetwork: true)
            } catch {
                Log.error("DevicesViewModel: failed to revoke installation: \(error)")
                lastErrorMessage = "Couldn't remove the device. Try again."
            }
        }
    }

    func startPairing() {
        let service = pairingServiceFactory()
        let vm = PairingSheetViewModel(
            pairingService: service,
            appGroupIdentifier: appGroupIdentifier
        )
        pairingViewModel = vm
        showPairingSheet = true
    }

    func stopPairing() {
        if let pairingViewModel {
            Task { await pairingViewModel.cancel() }
        }
        pairingViewModel = nil
    }

    /// libxmtp installation ids are 64-char hex strings; that's not a useful
    /// display name. We don't yet have a "name" channel for paired devices
    /// (the initiator's `deviceName` arrived in the pairing handshake but
    /// isn't persisted anywhere queryable from the libxmtp side). For now,
    /// surface a short tail-fingerprint so the row is identifiable.
    private static func shortDeviceName(installationId: String) -> String {
        let suffix = installationId.suffix(6)
        return "Device \(suffix)"
    }
}
