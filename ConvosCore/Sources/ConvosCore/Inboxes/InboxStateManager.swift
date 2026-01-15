import Foundation
import Observation

public protocol InboxStateObserver: AnyObject {
    func inboxStateDidChange(_ state: InboxStateMachine.State)
}

public protocol InboxStateManagerProtocol: AnyObject, Sendable {
    var currentState: InboxStateMachine.State { get }

    func waitForInboxReadyResult() async throws -> InboxReadyResult
    func reauthorize(inboxId: String, clientId: String) async throws -> InboxReadyResult
    func delete() async throws
    func waitForDeletionComplete() async
    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async throws

    func addObserver(_ observer: InboxStateObserver)
    func removeObserver(_ observer: InboxStateObserver)

    func observeState(_ handler: @escaping (InboxStateMachine.State) -> Void) -> StateObserverHandle
}

/// Manages and observes the state of an XMTP inbox
///
/// InboxStateManager provides Observable state tracking for an inbox's lifecycle
/// (idle, authorizing, ready, error). It wraps the InboxStateMachine and exposes
/// the current state to SwiftUI views and other observers. The manager handles
/// waiting for ready states, reauthorization flows, and provides both protocol-based
/// and closure-based observation patterns.
@Observable
public final class InboxStateManager: InboxStateManagerProtocol {
    public private(set) var currentState: InboxStateMachine.State
    public private(set) var isReady: Bool = false
    public private(set) var hasError: Bool = false
    public private(set) var errorMessage: String?

    private(set) weak var stateMachine: InboxStateMachine?
    private var stateTask: Task<Void, Never>?
    private var observers: [WeakObserver] = []

    private struct WeakObserver {
        weak var observer: InboxStateObserver?
    }

    public init(stateMachine: InboxStateMachine) {
        currentState = .idle(clientId: stateMachine.initialClientId)
        observe(stateMachine)
    }

    deinit {
        observers.removeAll()
        stateTask?.cancel()
    }

    private func observe(_ stateMachine: InboxStateMachine) {
        self.stateMachine = stateMachine
        stateTask?.cancel()

        stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in await stateMachine.stateSequence {
                await self.handleStateChange(state)
            }
        }
    }

    private func handleStateChange(_ state: InboxStateMachine.State) async {
        currentState = state
        isReady = state.isReady

        switch state {
        case .error(_, let error):
            hasError = true
            errorMessage = error.localizedDescription
        default:
            hasError = false
            errorMessage = nil
        }

        notifyObservers(state)
    }

    public func addObserver(_ observer: InboxStateObserver) {
        observers.removeAll { $0.observer == nil }
        observers.append(WeakObserver(observer: observer))
        observer.inboxStateDidChange(currentState)
    }

    public func removeObserver(_ observer: InboxStateObserver) {
        observers.removeAll { $0.observer === observer }
    }

    private func notifyObservers(_ state: InboxStateMachine.State) {
        observers = observers.compactMap { weakObserver in
            guard let observer = weakObserver.observer else { return nil }
            observer.inboxStateDidChange(state)
            return weakObserver
        }
    }

    public func waitForInboxReadyResult() async throws -> InboxReadyResult {
        guard let stateMachine = stateMachine else {
            throw InboxStateError.inboxNotReady
        }

        for await state in await stateMachine.stateSequence {
            switch state {
            case .ready(_, let result):
                return result
            case .error(_, let error):
                throw error
            default:
                continue
            }
        }

        throw InboxStateError.inboxNotReady
    }

    public func delete() async throws {
        guard let stateMachine = stateMachine else {
            throw InboxStateError.inboxNotReady
        }
        await stateMachine.stopAndDelete()
        await stateMachine.waitForDeletionComplete()
    }

    public func waitForDeletionComplete() async {
        guard let stateMachine = stateMachine else {
            return
        }
        await stateMachine.waitForDeletionComplete()
    }

    public func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async throws {
        guard let stateMachine = stateMachine else {
            throw InboxStateError.inboxNotReady
        }
        await stateMachine.setInviteJoinErrorHandler(handler)
    }

    public func reauthorize(inboxId: String, clientId: String) async throws -> InboxReadyResult {
        guard let stateMachine = stateMachine else {
            throw InboxStateError.inboxNotReady
        }

        // Check if we're already authorized with this inbox
        if case .ready(let currentClientId, let result) = currentState,
           result.client.inboxId == inboxId && currentClientId == clientId {
            Log
                .info(
                    "Already authorized with inbox \(inboxId) and clientId \(clientId), skipping reauthorization"
                )
            return result
        }

        Log.info("Reauthorizing with inbox \(inboxId)...")

        // Stop current inbox if running
        if case .ready = currentState {
            await stateMachine.stop()
            // Wait for the stop to complete (state should transition away from ready)
            for await state in await stateMachine.stateSequence {
                if case .idle = state {
                    break
                }
            }
        }

        // Authorize with the new inbox
        await stateMachine.authorize(inboxId: inboxId, clientId: clientId)

        // Wait for ready state with the new inboxId
        for await state in await stateMachine.stateSequence {
            switch state {
            case .ready(_, let result):
                // Verify this is the inbox we requested
                if result.client.inboxId == inboxId {
                    Log.info("Successfully reauthorized to inbox \(inboxId)")
                    return result
                } else {
                    // This is the old inbox's ready state, keep waiting
                    Log
                        .info(
                            "Waiting for correct inbox... current: \(result.client.inboxId), expected: \(inboxId)"
                        )
                    continue
                }
            case .error(_, let error):
                throw error
            default:
                continue
            }
        }

        throw InboxStateError.inboxNotReady
    }

    public func observeState(_ handler: @escaping (InboxStateMachine.State) -> Void) -> StateObserverHandle {
        let observer = ClosureStateObserver(handler: handler)
        addObserver(observer)
        return StateObserverHandle(observer: observer, manager: self)
    }
}

public final class ClosureStateObserver: InboxStateObserver {
    private let handler: (InboxStateMachine.State) -> Void

    init(handler: @escaping (InboxStateMachine.State) -> Void) {
        self.handler = handler
    }

    public func inboxStateDidChange(_ state: InboxStateMachine.State) {
        handler(state)
    }
}

public final class StateObserverHandle {
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
    }

    deinit {
        cancel()
    }
}
