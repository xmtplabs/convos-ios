import Combine
import ConvosInvites
import ConvosMessagingProtocols
import Foundation

/// Mock implementation of SessionStateManagerProtocol for testing
public final class MockSessionStateManager: SessionStateManagerProtocol, @unchecked Sendable {
    public var currentState: SessionStateMachine.State
    public var isSyncReady: Bool = true

    private var observers: [WeakStateObserver] = []
    private let mockClient: any MessagingClient
    private let mockAPIClient: any ConvosAPIClientProtocol

    private struct WeakStateObserver {
        weak var observer: SessionStateObserver?
    }

    public init(
        initialState: SessionStateMachine.State? = nil,
        mockClient: (any MessagingClient)? = nil,
        mockAPIClient: (any ConvosAPIClientProtocol)? = nil
    ) {
        self.mockClient = mockClient ?? MockMessagingClient()
        self.mockAPIClient = mockAPIClient ?? MockAPIClient()
        self.currentState = initialState ?? .idle
    }

    public func waitForInboxReadyResult() async throws -> InboxReadyResult {
        InboxReadyResult(client: mockClient, apiClient: mockAPIClient)
    }

    public func waitForDeletionComplete() async {
        currentState = .idle
        notifyObservers()
    }

    public func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async {
    }

    public func setTypingIndicatorHandler(_ handler: @escaping @Sendable (String, String, Bool) -> Void) async {
    }

    public func requestDiscovery() async {
    }

    public func addObserver(_ observer: any SessionStateObserver) {
        observers.removeAll { $0.observer == nil }
        observers.append(WeakStateObserver(observer: observer))
        observer.sessionStateDidChange(currentState)
    }

    public func removeObserver(_ observer: any SessionStateObserver) {
        observers.removeAll { $0.observer === observer || $0.observer == nil }
    }

    public func observeState(_ handler: @escaping (SessionStateMachine.State) -> Void) -> StateObserverHandle {
        let observer = ClosureStateObserver(handler: handler)
        addObserver(observer)
        return StateObserverHandle(observer: observer, manager: self)
    }

    // MARK: - Test Helpers

    /// Manually update the state and notify observers
    public func setState(_ state: SessionStateMachine.State) {
        currentState = state
        notifyObservers()
    }

    private func notifyObservers() {
        observers = observers.compactMap { weakObserver in
            guard let observer = weakObserver.observer else { return nil }
            observer.sessionStateDidChange(currentState)
            return weakObserver
        }
    }
}
