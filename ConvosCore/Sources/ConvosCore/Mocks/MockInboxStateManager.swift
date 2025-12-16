import Combine
import Foundation

/// Mock implementation of InboxStateManagerProtocol for testing
public final class MockInboxStateManager: InboxStateManagerProtocol, @unchecked Sendable {
    public var currentState: InboxStateMachine.State

    private var observers: [WeakStateObserver] = []
    private let mockClient: any XMTPClientProvider
    private let mockAPIClient: any ConvosAPIClientProtocol

    private struct WeakStateObserver {
        weak var observer: InboxStateObserver?
    }

    public init(
        initialState: InboxStateMachine.State? = nil,
        mockClient: (any XMTPClientProvider)? = nil,
        mockAPIClient: (any ConvosAPIClientProtocol)? = nil
    ) {
        self.mockClient = mockClient ?? MockXMTPClientProvider()
        self.mockAPIClient = mockAPIClient ?? MockAPIClient()
        self.currentState = initialState ?? .idle(clientId: "mock-client-id")
    }

    public func waitForInboxReadyResult() async throws -> InboxReadyResult {
        InboxReadyResult(client: mockClient, apiClient: mockAPIClient)
    }

    public func reauthorize(inboxId: String, clientId: String) async throws -> InboxReadyResult {
        InboxReadyResult(client: mockClient, apiClient: mockAPIClient)
    }

    public func delete() async throws {
        currentState = .idle(clientId: currentState.clientId)
        notifyObservers()
    }

    public func waitForDeletionComplete() async {
        currentState = .idle(clientId: currentState.clientId)
        notifyObservers()
    }

    public func addObserver(_ observer: any InboxStateObserver) {
        observers.removeAll { $0.observer == nil }
        observers.append(WeakStateObserver(observer: observer))
        observer.inboxStateDidChange(currentState)
    }

    public func removeObserver(_ observer: any InboxStateObserver) {
        observers.removeAll { $0.observer === observer || $0.observer == nil }
    }

    public func observeState(_ handler: @escaping (InboxStateMachine.State) -> Void) -> StateObserverHandle {
        let observer = ClosureStateObserver(handler: handler)
        addObserver(observer)
        return StateObserverHandle(observer: observer, manager: self)
    }

    // MARK: - Test Helpers

    /// Manually update the state and notify observers
    public func setState(_ state: InboxStateMachine.State) {
        currentState = state
        notifyObservers()
    }

    private func notifyObservers() {
        observers = observers.compactMap { weakObserver in
            guard let observer = weakObserver.observer else { return nil }
            observer.inboxStateDidChange(currentState)
            return weakObserver
        }
    }
}
