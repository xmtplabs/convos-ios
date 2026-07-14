import Foundation

/// Record of which XMTP installation this device most recently ran for an
/// inbox, kept in the device-local keychain so it survives app deletion
/// (the installation keys themselves live in the app container's database
/// and do not).
///
/// The iOS keychain outliving the app is what makes reinstall churn
/// possible: a reinstall resumes the identity from the keychain but must
/// mint a new installation, permanently orphaning the previous one - its
/// keys died with the deleted database, yet it stays registered on the
/// inbox and shows up as a ghost "Device <hex>" row in the devices list.
/// Comparing this marker against the live installation on launch is the
/// only way to prove an installation was this device's own dead one (and
/// not a legitimately paired device), which makes it safe to auto-revoke.
public struct InstallationMarker: Codable, Sendable, Equatable {
    public let inboxId: String
    public let installationId: String
    /// Installations this device orphaned but has not yet successfully
    /// revoked - carried across launches so an offline launch retries
    /// later instead of leaking the ghost forever. Growth is bounded in
    /// practice by requiring a full reinstall cycle per entry while every
    /// revoke attempt keeps failing; the first launch with network
    /// drains the whole list in one revoke call.
    public let staleInstallationIds: [String]

    public init(inboxId: String, installationId: String, staleInstallationIds: [String]) {
        self.inboxId = inboxId
        self.installationId = installationId
        self.staleInstallationIds = staleInstallationIds
    }
}

/// Pure planning logic for reconciling the installation marker against
/// the live session, split from the keychain and network plumbing so it
/// can be unit tested.
enum StaleInstallationReconciler {
    struct Plan: Equatable {
        /// Marker to persist for this launch (records any newly-orphaned
        /// installation before the revoke attempt, so a crash or network
        /// failure retries on the next launch).
        let marker: InstallationMarker
        /// This device's own dead installations, candidates for
        /// revocation once filtered against the live installation list.
        let candidateStaleIds: [String]
    }

    /// A nil or foreign-inbox marker carries no history worth acting on:
    /// first run of a build with marker support, or the identity was
    /// replaced wholesale (pairing adoption, delete-all) - in both cases
    /// any previous installation belongs to an abandoned inbox that the
    /// devices list never shows, so revoking it is pointless. Start
    /// fresh. Otherwise every installation id this marker saw that isn't
    /// the current one is provably this device's own dead installation.
    static func plan(
        marker: InstallationMarker?,
        inboxId: String,
        installationId: String
    ) -> Plan {
        guard let marker, marker.inboxId == inboxId else {
            return Plan(
                marker: InstallationMarker(inboxId: inboxId, installationId: installationId, staleInstallationIds: []),
                candidateStaleIds: []
            )
        }
        var stale = marker.staleInstallationIds
        if marker.installationId != installationId {
            stale.append(marker.installationId)
        }
        var seen = Set<String>()
        let filtered = stale.filter { $0 != installationId && seen.insert($0).inserted }
        return Plan(
            marker: InstallationMarker(inboxId: inboxId, installationId: installationId, staleInstallationIds: filtered),
            candidateStaleIds: filtered
        )
    }
}
