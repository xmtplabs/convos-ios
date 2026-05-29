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

    /// Stack 2 T17: force-drop the iOS-side push topic hash cache AND
    /// fire a fresh full reconcile, regardless of whether the conversation
    /// set changed. Intended for the debug screen's "Force Reconcile"
    /// button so an engineer can exercise the full subscribe path on
    /// demand. Production code should NEVER call this; routine state
    /// changes are covered by the cache key partitioning and the D14
    /// token-change listener.
    func forceReconcilePushTopics() async

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
