import ConvosInvites
import Foundation

public protocol SessionStateObserver: AnyObject, Sendable {
    func sessionStateDidChange(_ state: SessionStateMachine.State)
}

public protocol SessionStateManagerProtocol: AnyObject, Sendable {
    var currentState: SessionStateMachine.State { get }
    var isSyncReady: Bool { get async }

    func waitForInboxReadyResult() async throws -> InboxReadyResult
    func waitForDeletionComplete() async
    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async
    func setTypingIndicatorHandler(_ handler: @escaping @Sendable (String, String, Bool) -> Void) async

    func requestDiscovery() async

    /// Re-ingests every message libxmtp holds locally, ignoring catch-up
    /// cursors. Called after a post-pairing history sync request so that
    /// archive-imported messages (original timestamps, no stream events)
    /// reach the app database. No-ops when streaming services are off.
    func runHistorySyncBackfill() async

    /// Temporary diagnostic for agents timing out while joining. Starts a
    /// bounded poll for unprocessed join-request DMs in case the message
    /// stream has died. See `SyncingManager.startAgentJoinRequestPolling`.
    func startAgentJoinRequestPolling() async

    func addObserver(_ observer: SessionStateObserver)
    func removeObserver(_ observer: SessionStateObserver)

    func observeState(_ handler: @escaping (SessionStateMachine.State) -> Void) -> StateObserverHandle
}

/// @unchecked Sendable: Immutable handler invoked from async observation context.
public final class ClosureStateObserver: SessionStateObserver, @unchecked Sendable {
    private let handler: (SessionStateMachine.State) -> Void

    public init(handler: @escaping (SessionStateMachine.State) -> Void) {
        self.handler = handler
    }

    public func sessionStateDidChange(_ state: SessionStateMachine.State) {
        handler(state)
    }
}

/// @unchecked Sendable: Mutation limited to idempotent cancel().
public final class StateObserverHandle: @unchecked Sendable {
    private var observer: ClosureStateObserver?
    private weak var manager: (any SessionStateManagerProtocol)?

    init(observer: ClosureStateObserver, manager: any SessionStateManagerProtocol) {
        self.observer = observer
        self.manager = manager
    }

    public func cancel() {
        if let observer = observer {
            manager?.removeObserver(observer)
        }
        observer = nil
        manager = nil
    }

    deinit {
        cancel()
    }
}
