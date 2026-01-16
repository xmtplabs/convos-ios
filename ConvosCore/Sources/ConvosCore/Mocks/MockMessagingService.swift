#if canImport(UIKit)
import UIKit
#endif
import Combine
import Foundation
@preconcurrency import XMTPiOS

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
    private let _reactionWriter: any ReactionWriterProtocol

    // MARK: - Initialization

    public init(
        inboxStateManager: (any InboxStateManagerProtocol)? = nil,
        myProfileWriter: (any MyProfileWriterProtocol)? = nil,
        conversationStateManager: (any ConversationStateManagerProtocol)? = nil,
        conversationConsentWriter: (any ConversationConsentWriterProtocol)? = nil,
        conversationLocalStateWriter: (any ConversationLocalStateWriterProtocol)? = nil,
        conversationMetadataWriter: (any ConversationMetadataWriterProtocol)? = nil,
        conversationPermissionsRepository: (any ConversationPermissionsRepositoryProtocol)? = nil,
        outgoingMessageWriter: (any OutgoingMessageWriterProtocol)? = nil,
        reactionWriter: (any ReactionWriterProtocol)? = nil
    ) {
        self._inboxStateManager = inboxStateManager ?? MockInboxStateManager()
        self._myProfileWriter = myProfileWriter ?? MockMyProfileWriter()
        self._conversationStateManager = conversationStateManager ?? MockConversationStateManager()
        self._conversationConsentWriter = conversationConsentWriter ?? MockConversationConsentWriter()
        self._conversationLocalStateWriter = conversationLocalStateWriter ?? MockConversationLocalStateWriter()
        self._conversationMetadataWriter = conversationMetadataWriter ?? MockConversationMetadataWriter()
        self._conversationPermissionsRepository = conversationPermissionsRepository ?? MockConversationPermissionsRepository()
        self._outgoingMessageWriter = outgoingMessageWriter ?? MockOutgoingMessageWriter()
        self._reactionWriter = reactionWriter ?? MockReactionWriter()
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

    public func reactionWriter() -> any ReactionWriterProtocol {
        _reactionWriter
    }

    #if canImport(UIKit)
    public func photoMessageWriter(for conversationId: String) -> any OutgoingPhotoMessageWriterProtocol {
        MockOutgoingPhotoMessageWriter()
    }
    #endif

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

    public func setConversationNotificationsEnabled(_ enabled: Bool, for conversationId: String) async throws {
        try await _conversationLocalStateWriter.setMuted(!enabled, for: conversationId)
    }
}

#if canImport(UIKit)
public final class MockOutgoingPhotoMessageWriter: OutgoingPhotoMessageWriterProtocol, @unchecked Sendable {
    private let sentMessageSubject: PassthroughSubject<String, Never> = PassthroughSubject<String, Never>()

    public var sentMessage: AnyPublisher<String, Never> {
        sentMessageSubject.eraseToAnyPublisher()
    }

    public init() {}

    public func send(image: UIImage) async throws {
        let mockURL = "https://example.com/photos/mock_photo.jpg"
        sentMessageSubject.send(mockURL)
    }
}
#endif
