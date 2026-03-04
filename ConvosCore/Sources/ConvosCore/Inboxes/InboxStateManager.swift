import ConvosInvites
import Foundation

public protocol InboxStateObserver: AnyObject, Sendable {
    func inboxStateDidChange(_ state: InboxStateMachine.State)
}

public protocol InboxStateManagerProtocol: AnyObject, Sendable {
    var currentState: InboxStateMachine.State { get }
    var isSyncReady: Bool { get async }

    func waitForInboxReadyResult() async throws -> InboxReadyResult
    func reauthorize(inboxId: String, clientId: String) async throws -> InboxReadyResult
    func deleteInbox() async throws
    func waitForDeletionComplete() async
    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async

    func requestDiscovery() async

    func addObserver(_ observer: InboxStateObserver)
    func removeObserver(_ observer: InboxStateObserver)

    func observeState(_ handler: @escaping (InboxStateMachine.State) -> Void) -> StateObserverHandle
}

/// @unchecked Sendable: Immutable handler invoked from async observation context.
public final class ClosureStateObserver: InboxStateObserver, @unchecked Sendable {
    private let handler: (InboxStateMachine.State) -> Void

    init(handler: @escaping (InboxStateMachine.State) -> Void) {
        self.handler = handler
    }

    public func inboxStateDidChange(_ state: InboxStateMachine.State) {
        handler(state)
    }
}

/// @unchecked Sendable: Mutation limited to idempotent cancel().
public final class StateObserverHandle: @unchecked Sendable {
    private var observer: ClosureStateObserver?
    private weak var manager: (any InboxStateManagerProtocol)?

    init(observer: ClosureStateObserver, manager: any InboxStateManagerProtocol) {
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
