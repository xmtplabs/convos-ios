import Foundation

/// Hands a verified pairing join request from the Notification Service
/// Extension to the main app. The NSE can't present the pairing sheet, so
/// it stashes the request here (and shows a "<device> is requesting to
/// pair" banner); the app consumes the stash on its next activation and
/// presents the initiator flow. Also acts as the NSE's notification
/// dedupe: the joiner re-sends its request every few seconds, and one
/// banner per request burst is plenty.
///
/// Storage is app-group UserDefaults so both processes see it, mirroring
/// `PairedDeviceNameStore`. UserDefaults is process-safe.
public enum PendingPairRequestStore {
    /// Display metadata only - deliberately no invite slug. A valid
    /// unexpired slug is a bearer credential (it passes
    /// `PairingJoinRequestDetector.verify` from any inbox), and the
    /// app-group plist is plaintext and included in device backups; the
    /// consumer only needs the joiner identity and a name to present
    /// the PIN sheet.
    public struct Pending: Codable, Sendable, Equatable {
        public let joinerInboxId: String
        public let deviceName: String
        public let receivedAt: Date

        public init(joinerInboxId: String, deviceName: String, receivedAt: Date) {
            self.joinerInboxId = joinerInboxId
            self.deviceName = deviceName
            self.receivedAt = receivedAt
        }
    }

    private static let pendingKey: String = "convos.pairing.pendingJoinRequest.v1"

    private static func defaults(for appGroup: String) -> UserDefaults {
        guard let suite = UserDefaults(suiteName: appGroup) else {
            // Falling back means the NSE and the app each write their own
            // standard defaults and the handoff silently never happens -
            // make that observable.
            Log.warning("PendingPairRequestStore: app-group suite unavailable, falling back to standard defaults")
            return .standard
        }
        return suite
    }

    /// Stashes the request, replacing any previous one.
    public static func setPending(_ pending: Pending, appGroup: String) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        defaults(for: appGroup).set(data, forKey: pendingKey)
    }

    /// Reads without clearing. The NSE uses this for dedupe decisions.
    public static func pending(appGroup: String) -> Pending? {
        guard let data = defaults(for: appGroup).data(forKey: pendingKey) else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: data)
    }

    /// Reads and clears. The app calls this on activation, and also when
    /// the stream path presents a request directly - the NSE stashes for
    /// pushes that arrive while the app is foregrounded too, and a stash
    /// left behind after the flow was handled would re-present a ghost
    /// PIN sheet on the next activation.
    public static func consumePending(appGroup: String) -> Pending? {
        let defs = defaults(for: appGroup)
        guard let data = defs.data(forKey: pendingKey) else { return nil }
        defs.removeObject(forKey: pendingKey)
        return try? JSONDecoder().decode(Pending.self, from: data)
    }
}

/// Thread identifier stamped on every "is requesting to pair"
/// notification - the NSE's remote ones (via
/// `DecodedNotificationContent.conversationId`, which the extension maps
/// to `threadIdentifier`) and the app's local one - so the system
/// collapses a resend burst into one thread and the app's activation
/// cleanup can remove NSE-posted banners whose request identifiers are
/// system-assigned.
public enum PairingNotificationThread {
    public static let identifier: String = "incoming-pairing-request"
}
