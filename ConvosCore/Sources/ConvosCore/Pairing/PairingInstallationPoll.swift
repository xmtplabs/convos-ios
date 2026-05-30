import Foundation

/// Shared cadence for waiting on a just-paired joiner's installation to
/// surface in the inbox's installation list. libxmtp's
/// `listInstallations(refreshFromNetwork:)` reflects network-side state that
/// lags the joiner's key-package publish by a few seconds, so both the
/// initiator's optimistic-row reconciliation (`DevicesViewModel`) and the
/// post-pair profile broadcaster (`PostPairProfileSnapshotBroadcaster`) poll
/// on this schedule.
public enum PairingInstallationPoll {
    /// Seconds to wait before each poll attempt. Cumulative ~37s, roughly
    /// exponential: long enough to catch the key-package publish, short
    /// enough not to hang on a pair that never completes.
    public static let schedule: [TimeInterval] = [0, 2, 5, 10, 20]
}
