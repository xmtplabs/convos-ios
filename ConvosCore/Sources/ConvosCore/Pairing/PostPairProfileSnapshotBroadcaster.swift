import Foundation

/// Narrow slice of `MessagingServiceProtocol` the post-pair broadcaster
/// needs. Segregating it keeps the broadcaster unit-testable with a tiny
/// double instead of the full messaging-service surface.
/// `MessagingServiceProtocol` inherits this, so `any MessagingServiceProtocol`
/// satisfies it directly.
public protocol PostPairBroadcastMessaging: Sendable {
    func installationsSnapshot(refreshFromNetwork: Bool) async throws -> InstallationsSnapshot
    @discardableResult
    func broadcastProfileSnapshotsToAllGroups() async -> Int
}

public protocol PostPairProfileSnapshotBroadcasterProtocol: Sendable {
    /// Waits for an installation outside `baseline` to appear in the
    /// inbox's installation set, then broadcasts a `ProfileSnapshot` to
    /// every group the initiator is in. One-shot; idempotent if called
    /// multiple times (each call independently polls + sends).
    ///
    /// `baseline` MUST be captured before the joiner's installation could
    /// have surfaced -- i.e. at the moment pairing completes, before any
    /// install-list refresh that waits for the joiner. Capturing it later
    /// (e.g. after a poll that already saw the joiner) folds the joiner
    /// into the baseline, so the diff finds nothing new and the broadcast
    /// never fires.
    ///
    /// Returns `true` if an installation beyond `baseline` was detected
    /// within the polling window and the broadcast ran; `false` if the
    /// window elapsed with no new installation visible (snapshot send is
    /// skipped in that case, since the new installation is the whole
    /// reason we'd send).
    func runAfterPairing(baseline: Set<String>) async -> Bool
}

/// Orchestrates the initiator-side post-pair profile-snapshot fan-out.
///
/// Pairing context: after the joiner adopts the initiator's identity
/// (`LivePairingService.handleIdentityShare`), the joiner re-bootstraps
/// under the shared `inboxId` and publishes its installation
/// key-package. The XMTP network surfaces the new installation in the
/// inbox's installations list a few seconds later. From the joiner's
/// perspective the conversations exist (libxmtp adds the joiner's
/// installation to each group's MLS state via UpdateGroupMembership
/// commits), but the joiner's local DB has no `DBMemberProfile` rows
/// yet — those get populated by inbound `ProfileUpdate` /
/// `ProfileSnapshot` messages. Without a freshly-sent snapshot the
/// joiner waits on libxmtp's history sync to replay old snapshots,
/// which can be slow or partial.
///
/// This broadcaster makes the catch-up explicit: poll until a new
/// installation appears, then have the initiator's `MessagingService`
/// send a fresh `ProfileSnapshot` (built from every group's current
/// members) to every group. The joiner's installation, now part of
/// each group, receives those snapshots via its regular message
/// stream and hydrates its local DB.
public final class PostPairProfileSnapshotBroadcaster: PostPairProfileSnapshotBroadcasterProtocol, @unchecked Sendable {
    private let messagingService: any PostPairBroadcastMessaging
    private let pollSchedule: [TimeInterval]

    public init(messagingService: any PostPairBroadcastMessaging) {
        self.messagingService = messagingService
        self.pollSchedule = Constant.pollSchedule
    }

    /// Test seam: inject a faster poll schedule so unit tests don't sleep
    /// through the production cadence.
    init(messagingService: any PostPairBroadcastMessaging, pollSchedule: [TimeInterval]) {
        self.messagingService = messagingService
        self.pollSchedule = pollSchedule
    }

    public func runAfterPairing(baseline: Set<String>) async -> Bool {
        // `baseline` is the installation set captured by the caller
        // *before* the post-pair install-list refresh ran, so the
        // joiner's just-published key-package is guaranteed to be absent
        // from it. Any installation that shows up beyond this set is the
        // joiner. (Capturing the baseline here, after the refresh already
        // waited for the joiner, would fold it in and the broadcast would
        // never fire.)
        let didAppear = await waitForInstallationAdded(beyond: baseline)
        guard didAppear else {
            Log.warning("PostPairProfileSnapshotBroadcaster: no new installation appeared within polling window; skipping snapshot fan-out")
            return false
        }
        let sent = await messagingService.broadcastProfileSnapshotsToAllGroups()
        Log.info("PostPairProfileSnapshotBroadcaster: broadcast ProfileSnapshot to \(sent) group(s)")
        return true
    }

    /// Polls libxmtp's installation list on the same schedule
    /// `DevicesViewModel` uses for its optimistic-row reconciliation.
    /// Returns true the first time we see an installation id that
    /// wasn't in the baseline set; false if the entire schedule
    /// elapses with no new installation.
    private func waitForInstallationAdded(beyond baseline: Set<String>) async -> Bool {
        for delay in pollSchedule {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard let current = await fetchInstallationIds() else { continue }
            if !current.subtracting(baseline).isEmpty { return true }
        }
        return false
    }

    /// One-shot install-list fetch returning the full set of ids.
    /// Returns nil on failure so the caller can distinguish "no new
    /// installation" from "we don't know what was there to begin
    /// with."
    private func fetchInstallationIds() async -> Set<String>? {
        do {
            let snapshot = try await messagingService.installationsSnapshot(refreshFromNetwork: true)
            return Set(snapshot.installations.map(\.id))
        } catch {
            Log.warning("PostPairProfileSnapshotBroadcaster: installationsSnapshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    private enum Constant {
        /// Matches `DevicesViewModel.refreshUntilRealInstallationAppears`:
        /// cumulative ~37s, roughly exponential. Long enough to catch
        /// the joiner's key-package publish, short enough that we don't
        /// hang on a never-completes pair.
        static let pollSchedule: [TimeInterval] = [0, 2, 5, 10, 20]
    }
}
