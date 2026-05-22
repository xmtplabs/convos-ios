import Foundation

/// Maps libxmtp `installationId` -> human-readable device name for paired
/// devices. Populated during pairing (initiator captures the joiner's
/// `deviceName` from `PairingJoinRequestContent`; joiner captures the
/// initiator's `deviceName` from `IdentityShareContent.initiatorDeviceName`).
/// Surfaced by `DevicesViewModel` when rendering the device list, instead
/// of the fallback `"Device <last-6-of-installationId>"`.
///
/// Storage is app-group UserDefaults so the NSE could read it too if it
/// ever needs to (it doesn't today). Survives reinstalls because the
/// app-group is preserved.
///
/// Concurrency: UserDefaults is process-safe; this is a value-type facade.
public enum PairedDeviceNameStore {
    private static let mapKey: String = "convos.pairing.deviceNames.v1"
    private static let pendingKey: String = "convos.pairing.pendingDeviceName.v1"

    private static func defaults(for appGroup: String) -> UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    /// Returns the persisted device name for the given installation id, if any.
    public static func name(forInstallationId installationId: String, appGroup: String) -> String? {
        let defs = defaults(for: appGroup)
        let map = (defs.dictionary(forKey: mapKey) as? [String: String]) ?? [:]
        return map[installationId]
    }

    /// Persists `name` keyed by `installationId`.
    public static func setName(_ name: String, forInstallationId installationId: String, appGroup: String) {
        let defs = defaults(for: appGroup)
        var map = (defs.dictionary(forKey: mapKey) as? [String: String]) ?? [:]
        map[installationId] = name
        defs.set(map, forKey: mapKey)
    }

    /// Stages a name for the next non-self installation that
    /// `DevicesViewModel.refreshInstallations` observes. Used by the
    /// pairing flow because the post-pair installation id isn't known
    /// to either side at the moment pairing succeeds — it's discovered
    /// later via `listInstallations(refreshFromNetwork:)`.
    public static func setPending(_ name: String, appGroup: String) {
        defaults(for: appGroup).set(name, forKey: pendingKey)
    }

    /// Reads and clears the pending name. Returns nil if none was staged.
    public static func consumePending(appGroup: String) -> String? {
        let defs = defaults(for: appGroup)
        let value = defs.string(forKey: pendingKey)
        defs.removeObject(forKey: pendingKey)
        return value
    }
}

public extension Notification.Name {
    /// Posted by the pairing flow after a successful pair completes on
    /// either side, so observers like `DevicesViewModel` can refresh
    /// installations (and claim any pending name).
    static let pairingDidCompleteSuccessfully = Notification.Name("convos.pairing.didCompleteSuccessfully")
}
