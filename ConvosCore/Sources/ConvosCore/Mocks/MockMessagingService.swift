import Combine
import Foundation
import XMTPiOS

/// Mock implementation of MessagingServiceProtocol for testing and previews
///
/// This mock uses separate mock implementations for each protocol it depends on,
/// making it easier to customize behavior for specific test scenarios.
public final class MockMessagingService: MessagingServiceProtocol, @unchecked Sendable {
    // MARK: - Dependencies

    private let _inboxStateManager: any InboxStateManagerProtocol
    private let _myProfileWriter: any MyProfileWriterProtocol
    private let _conversationStateManager: any ConversationStateManagerProtocol
    private let _conversationConsentWriter: any ConversationConsentWriterProtocol
    private let _conversationLocalStateWriter: any ConversationLocalStateWriterProtocol
    private let _conversationMetadataWriter: any ConversationMetadataWriterProtocol
    private let _conversationPermissionsRepository: any ConversationPermissionsRepositoryProtocol
    private let _outgoingMessageWriter: any OutgoingMessageWriterProtocol

    // MARK: - Initialization

    public init(
        inboxStateManager: (any InboxStateManagerProtocol)? = nil,
        myProfileWriter: (any MyProfileWriterProtocol)? = nil,
        conversationStateManager: (any ConversationStateManagerProtocol)? = nil,
        conversationConsentWriter: (any ConversationConsentWriterProtocol)? = nil,
        conversationLocalStateWriter: (any ConversationLocalStateWriterProtocol)? = nil,
        conversationMetadataWriter: (any ConversationMetadataWriterProtocol)? = nil,
        conversationPermissionsRepository: (any ConversationPermissionsRepositoryProtocol)? = nil,
        outgoingMessageWriter: (any OutgoingMessageWriterProtocol)? = nil
    ) {
        self._inboxStateManager = inboxStateManager ?? MockInboxStateManager()
        self._myProfileWriter = myProfileWriter ?? MockMyProfileWriter()
        self._conversationStateManager = conversationStateManager ?? MockConversationStateManager()
        self._conversationConsentWriter = conversationConsentWriter ?? MockConversationConsentWriter()
        self._conversationLocalStateWriter = conversationLocalStateWriter ?? MockConversationLocalStateWriter()
        self._conversationMetadataWriter = conversationMetadataWriter ?? MockConversationMetadataWriter()
        self._conversationPermissionsRepository = conversationPermissionsRepository ?? MockConversationPermissionsRepository()
        self._outgoingMessageWriter = outgoingMessageWriter ?? MockOutgoingMessageWriter()
    }

    // MARK: - MessagingServiceProtocol

    public func stop() {}

    public func stopAndDelete() {}

    public func stopAndDelete() async {}

    public func waitForDeletionComplete() async {}

    public var inboxStateManager: any InboxStateManagerProtocol {
        _inboxStateManager
    }

    public func myProfileWriter() -> any MyProfileWriterProtocol {
        _myProfileWriter
    }

    public func conversationStateManager() -> any ConversationStateManagerProtocol {
        _conversationStateManager
    }

    public func conversationStateManager(for conversationId: String) -> any ConversationStateManagerProtocol {
        MockConversationStateManager(conversationId: conversationId)
    }

    public func conversationConsentWriter() -> any ConversationConsentWriterProtocol {
        _conversationConsentWriter
    }

    public func messageWriter(for conversationId: String) -> any OutgoingMessageWriterProtocol {
        _outgoingMessageWriter
    }

    public func conversationLocalStateWriter() -> any ConversationLocalStateWriterProtocol {
        _conversationLocalStateWriter
    }

    public func conversationMetadataWriter() -> any ConversationMetadataWriterProtocol {
        _conversationMetadataWriter
    }

    public func conversationPermissionsRepository() -> any ConversationPermissionsRepositoryProtocol {
        _conversationPermissionsRepository
    }

    public func uploadImage(data: Data, filename: String) async throws -> String {
        "https://example.com/uploads/\(filename)"
    }

    public func uploadImageAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String {
        let uploadedURL = "https://example.com/uploads/\(filename)"
        try await afterUpload(uploadedURL)
        return uploadedURL
    }
}
