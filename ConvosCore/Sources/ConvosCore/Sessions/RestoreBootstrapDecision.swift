import Foundation

/// App-start decision that gates whether `SessionManager` may register a
/// fresh identity or run prewarm.
///
/// The restore prompt card is the only UI that advances the decision to
/// a terminal state. While the decision is `.unknown` or `.restoreAvailable`
/// the session layer stays inert so `SessionManager.loadOrCreateService()`
/// cannot take the `.register` branch and mint a new identity before the
/// user has had a chance to choose "Restore from backup" on first launch.
public enum RestoreBootstrapDecision: Sendable, Equatable {
    /// App hasn't decided yet (first launch, before the bootstrap check
    /// has run or while iCloud Keychain is still syncing).
    case unknown

    /// A compatible backup was discovered; the UI should show the restore
    /// card. Registration + prewarm remain blocked.
    case restoreAvailable

    /// Bootstrap ran and found no backup. Registration + prewarm are
    /// allowed; the app boots as a fresh install.
    case noRestoreAvailable

    /// User tapped "Start fresh" on the restore card. Registration is now
    /// allowed even though a backup exists.
    case dismissedByUser

    /// Restore completed. The existing identity is live and registration
    /// is not needed, but the gate is released so prewarm runs normally.
    case restoreSucceeded

    /// Whether the gate is still closed. `loadOrCreateService()` refuses
    /// to take the `.register` branch while this is `true`.
    public var blocksRegistration: Bool {
        switch self {
        case .unknown, .restoreAvailable:
            return true
        case .noRestoreAvailable, .dismissedByUser, .restoreSucceeded:
            return false
        }
    }
}

/// Error returned by `SessionManager.loadOrCreateService()` when it is
/// asked to build a service while the bootstrap gate is still closed.
/// `MessagingService` cache carries a frozen placeholder backed by this
/// error so repeated accessor calls don't thrash.
public struct RestoreDecisionPendingError: Error, LocalizedError {
    public var errorDescription: String? {
        "Waiting for restore decision before initializing the session."
    }

    public init() {}
}

public struct RestoreInProgressSessionError: Error, LocalizedError {
    public var errorDescription: String? {
        "Restore is in progress. The session will resume when it finishes."
    }

    public init() {}
}
