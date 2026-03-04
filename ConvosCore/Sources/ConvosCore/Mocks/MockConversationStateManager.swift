import Combine
import Foundation
import GRDB
import os

public final class MockConversationStateManager: ConversationStateManagerProtocol, @unchecked Sendable {
    private let stateLock: OSAllocatedUnfairLock<ConversationStateMachine.State> = .init(initialState: .uninitialized)

    public var currentState: ConversationStateMachine.State {
        stateLock.withLock { $0 }
    }

    private let continuationsLock: OSAllocatedUnfairLock<
        [(id: UUID, continuation: AsyncStream<ConversationStateMachine.State>.Continuation)]
    > = .init(initialState: [])

    public var stateSequence: AsyncStream<ConversationStateMachine.State> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let id = UUID()
            continuationsLock.withLock { $0.append((id: id, continuation: continuation)) }
            continuation.onTermination = { [weak self] _ in
                self?.continuationsLock.withLock { $0.removeAll { $0.id == id } }
            }
            continuation.yield(currentState)
        }
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

    // MARK: - DraftConversationWriterProtocol Methods

    public func createConversation() async throws {
        setState(.creating)
        try await Task.sleep(nanoseconds: 100_000_000)
        setState(.ready(ConversationReadyResult(conversationId: conversationId, origin: .created)))
    }

    public func joinConversation(inviteCode: String) async throws {
        setState(.validating(inviteCode: inviteCode))
        try await Task.sleep(nanoseconds: 100_000_000)
        setState(.ready(ConversationReadyResult(conversationId: conversationId, origin: .joined)))
    }

    public func send(text: String) async throws {}
    public func send(text: String, afterPhoto trackingKey: String?) async throws {}
    public func send(image: ImageType) async throws {}

    public func startEagerUpload(image: ImageType) async throws -> String {
        UUID().uuidString
    }

    public func sendEagerPhoto(trackingKey: String) async throws {}
    public func cancelEagerUpload(trackingKey: String) async {}
    public func sendReply(text: String, toMessageWithClientId parentClientMessageId: String) async throws {}
    public func sendEagerPhotoReply(trackingKey: String, toMessageWithClientId parentClientMessageId: String) async throws {}
    public func sendReply(text: String, afterPhoto trackingKey: String?, toMessageWithClientId parentClientMessageId: String) async throws {}

    public func delete() async {
        setState(.deleting)
        try? await Task.sleep(nanoseconds: 100_000_000)
        setState(.uninitialized)
    }

    public func resetFromError() async {
        setState(.uninitialized)
    }

    // MARK: - Test Helpers

    public func setState(_ state: ConversationStateMachine.State) {
        stateLock.withLock { $0 = state }
        let entries = continuationsLock.withLock { Array($0) }
        for entry in entries {
            entry.continuation.yield(state)
        }
    }
}
