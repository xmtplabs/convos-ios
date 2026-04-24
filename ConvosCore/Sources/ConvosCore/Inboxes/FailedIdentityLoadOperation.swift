import Foundation

/// Dedicated entry state for the "keychain read failed" branch of
/// `SessionManager.loadOrCreateService`. Constructed synchronously, holds
/// the real `Error` the keychain threw, and reports `.error(error)`
/// immediately. No task starts, no state machine is built. Teardown is a
/// no-op because there is nothing to tear down.
///
/// `MessagingService` wraps one of these the same way it wraps a real
/// `AuthorizeInboxOperation`; downstream code that inspects
/// `sessionStateManager.currentState` observes the authentic error and
/// can surface a "keychain unreadable — retry" prompt upstream.
final class FailedIdentityLoadOperation: AuthorizeInboxOperationProtocol, @unchecked Sendable {
    let stateMachine: FailedIdentityLoadSessionStateManager

    init(error: any Error) {
        self.stateMachine = FailedIdentityLoadSessionStateManager(error: error)
    }

    func stopAndDelete() async {}
    func stopAndDelete() {}
    func stop() {}
    func stop() async {}
}

/// Frozen `SessionStateManagerProtocol` for the failed-keychain-load path.
/// Always reports `.error(<the real keychain error>)`. All other methods
/// are no-ops or throw the held error — callers that `await
/// waitForInboxReadyResult()` get the underlying cause, not a synthesized
/// mismatch.
final class FailedIdentityLoadSessionStateManager: SessionStateManagerProtocol, @unchecked Sendable {
    private let error: any Error
    let currentState: SessionStateMachine.State
    var isSyncReady: Bool { get async { false } }

    init(error: any Error) {
        self.error = error
        self.currentState = .error(error)
    }

    func waitForInboxReadyResult() async throws -> InboxReadyResult {
        throw error
    }

    func waitForDeletionComplete() async {}
    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async {}
    func setTypingIndicatorHandler(_ handler: @escaping @Sendable (String, String, Bool) -> Void) async {}

    func requestDiscovery() async {}

    func addObserver(_ observer: SessionStateObserver) {
        observer.sessionStateDidChange(currentState)
    }

    func removeObserver(_ observer: SessionStateObserver) {}

    func observeState(_ handler: @escaping (SessionStateMachine.State) -> Void) -> StateObserverHandle {
        handler(currentState)
        let observer = ClosureStateObserver(handler: handler)
        return StateObserverHandle(observer: observer, manager: self)
    }
}
