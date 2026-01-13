import Combine
import Foundation
import GRDB

/// Mock implementation of ConversationStateManagerProtocol for testing
public final class MockConversationStateManager: ConversationStateManagerProtocol, @unchecked Sendable {
    // MARK: - State Properties

    public private(set) var currentState: ConversationStateMachine.State = .uninitialized
    private var observers: [WeakObserver] = []

    private struct WeakObserver {
        weak var observer: ConversationStateObserver?
    }

    // MARK: - DraftConversationWriterProtocol Properties

    private let conversationIdSubject: CurrentValueSubject<String, Never>

    public var conversationId: String {
        conversationIdSubject.value
    }

    public var conversationIdPublisher: AnyPublisher<String, Never> {
        conversationIdSubject.eraseToAnyPublisher()
    }

    public var sentMessage: AnyPublisher<String, Never> {
        Just("").eraseToAnyPublisher()
    }

    // MARK: - Dependencies

    public let myProfileWriter: any MyProfileWriterProtocol
    public let draftConversationRepository: any DraftConversationRepositoryProtocol
    public let conversationConsentWriter: any ConversationConsentWriterProtocol
    public let conversationLocalStateWriter: any ConversationLocalStateWriterProtocol
    public let conversationMetadataWriter: any ConversationMetadataWriterProtocol

    // MARK: - Initialization

    public init(
        conversationId: String? = nil,
        myProfileWriter: (any MyProfileWriterProtocol)? = nil,
        draftConversationRepository: (any DraftConversationRepositoryProtocol)? = nil,
        conversationConsentWriter: (any ConversationConsentWriterProtocol)? = nil,
        conversationLocalStateWriter: (any ConversationLocalStateWriterProtocol)? = nil,
        conversationMetadataWriter: (any ConversationMetadataWriterProtocol)? = nil
    ) {
        self.conversationIdSubject = .init(conversationId ?? "mock-conversation-\(UUID().uuidString)")
        self.myProfileWriter = myProfileWriter ?? MockMyProfileWriter()
        self.draftConversationRepository = draftConversationRepository ?? MockDraftConversationRepository()
        self.conversationConsentWriter = conversationConsentWriter ?? MockConversationConsentWriter()
        self.conversationLocalStateWriter = conversationLocalStateWriter ?? MockConversationLocalStateWriter()
        self.conversationMetadataWriter = conversationMetadataWriter ?? MockConversationMetadataWriter()
    }

    // MARK: - State Management

    public func waitForConversationReadyResult(timeout: TimeInterval = 10.0) async throws -> ConversationReadyResult {
        ConversationReadyResult(conversationId: conversationId, origin: .created)
    }

    // MARK: - Observer Management

    @MainActor
    public func addObserver(_ observer: ConversationStateObserver) {
        observers.removeAll { $0.observer == nil }
        observers.append(WeakObserver(observer: observer))
        observer.conversationStateDidChange(currentState)
    }

    @MainActor
    public func removeObserver(_ observer: ConversationStateObserver) {
        observers.removeAll { $0.observer === observer || $0.observer == nil }
    }

    @MainActor
    public func observeState(_ handler: @escaping (ConversationStateMachine.State) -> Void) -> ConversationStateObserverHandle {
        let observer = ClosureConversationStateObserver(handler: handler)
        addObserver(observer)
        return ConversationStateObserverHandle(observer: observer, manager: self)
    }

    // MARK: - DraftConversationWriterProtocol Methods

    public func createConversation() async throws {
        currentState = .creating
        notifyObservers(currentState)

        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second

        let result = ConversationReadyResult(conversationId: conversationId, origin: .created)
        currentState = .ready(result)
        notifyObservers(currentState)
    }

    public func joinConversation(inviteCode: String) async throws {
        currentState = .validating(inviteCode: inviteCode)
        notifyObservers(currentState)

        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second

        let result = ConversationReadyResult(conversationId: conversationId, origin: .joined)
        currentState = .ready(result)
        notifyObservers(currentState)
    }

    public func send(text: String) async throws {
        // Mock implementation - no-op
    }

    public func delete() async {
        currentState = .deleting
        notifyObservers(currentState)

        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second

        currentState = .uninitialized
        notifyObservers(currentState)
    }

    public func resetFromError() async {
        currentState = .uninitialized
        notifyObservers(currentState)
    }

    // MARK: - Test Helpers

    /// Manually update the state and notify observers
    public func setState(_ state: ConversationStateMachine.State) {
        currentState = state
        notifyObservers(currentState)
    }

    // MARK: - Private Helpers

    private func notifyObservers(_ state: ConversationStateMachine.State) {
        observers = observers.compactMap { weakObserver in
            guard let observer = weakObserver.observer else { return nil }
            observer.conversationStateDidChange(state)
            return weakObserver
        }
    }
}
