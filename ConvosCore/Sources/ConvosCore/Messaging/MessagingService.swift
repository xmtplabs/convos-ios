import Combine
import Foundation
import GRDB
import XMTPiOS

/// Service for managing XMTP messaging for a single inbox
///
/// MessagingService coordinates all messaging operations for one inbox identity,
/// including message sending/receiving, conversation management, and member operations.
/// Each service instance manages one XMTP client through the InboxStateManager and
/// provides factory methods for creating writers and repositories scoped to this inbox.
/// The service handles authorization, streaming, and push notification registration.
final class MessagingService: MessagingServiceProtocol {
    private let authorizationOperation: any AuthorizeInboxOperationProtocol
    let inboxStateManager: any InboxStateManagerProtocol
    internal let identityStore: any KeychainIdentityStoreProtocol
    internal let databaseReader: any DatabaseReader
    internal let databaseWriter: any DatabaseWriter
    private let environment: AppEnvironment
    private var cancellables: Set<AnyCancellable> = []

    // swiftlint:disable:next function_parameter_count
    static func authorizedMessagingService(
        for inboxId: String,
        clientId: String,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment,
        identityStore: any KeychainIdentityStoreProtocol,
        startsStreamingServices: Bool,
        overrideJWTToken: String? = nil,
        platformProviders: PlatformProviders
    ) -> MessagingService {
        let authorizationOperation = AuthorizeInboxOperation.authorize(
            inboxId: inboxId,
            clientId: clientId,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            startsStreamingServices: startsStreamingServices,
            overrideJWTToken: overrideJWTToken,
            platformProviders: platformProviders
        )
        return MessagingService(
            authorizationOperation: authorizationOperation,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            identityStore: identityStore,
            environment: environment
        )
    }

    internal init(authorizationOperation: AuthorizeInboxOperation,
                  databaseWriter: any DatabaseWriter,
                  databaseReader: any DatabaseReader,
                  identityStore: any KeychainIdentityStoreProtocol,
                  environment: AppEnvironment) {
        self.identityStore = identityStore
        self.authorizationOperation = authorizationOperation
        self.inboxStateManager = InboxStateManager(stateMachine: authorizationOperation.stateMachine)
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter
        self.environment = environment
    }

    deinit {
        cancellables.removeAll()
    }

    // MARK: State

    func stop() {
        authorizationOperation.stop()
    }

    func stopAndDelete() {
        authorizationOperation.stopAndDelete()
    }

    func stopAndDelete() async {
        await authorizationOperation.stopAndDelete()
    }

    func waitForDeletionComplete() async {
        await inboxStateManager.waitForDeletionComplete()
    }

    // MARK: My Profile

    func myProfileWriter() -> any MyProfileWriterProtocol {
        MyProfileWriter(inboxStateManager: inboxStateManager, databaseWriter: databaseWriter)
    }

    // MARK: New Conversation

    func conversationStateManager() -> any ConversationStateManagerProtocol {
        return ConversationStateManager(
            inboxStateManager: inboxStateManager,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment
        )
    }

    // MARK: Existing Conversation

    func conversationStateManager(for conversationId: String) -> any ConversationStateManagerProtocol {
        return ConversationStateManager(
            inboxStateManager: inboxStateManager,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            conversationId: conversationId
        )
    }

    // MARK: Conversations

    func conversationConsentWriter() -> any ConversationConsentWriterProtocol {
        ConversationConsentWriter(
            inboxStateManager: inboxStateManager,
            databaseWriter: databaseWriter
        )
    }

    func conversationLocalStateWriter() -> any ConversationLocalStateWriterProtocol {
        ConversationLocalStateWriter(databaseWriter: databaseWriter)
    }

    // MARK: Getting/Sending Messages

    func messageWriter(for conversationId: String) -> any OutgoingMessageWriterProtocol {
        OutgoingMessageWriter(inboxStateManager: inboxStateManager,
                              databaseWriter: databaseWriter,
                              conversationId: conversationId)
    }

    // MARK: - Group Management

    func conversationMetadataWriter() -> any ConversationMetadataWriterProtocol {
        ConversationMetadataWriter(
            inboxStateManager: inboxStateManager,
            inviteWriter: InviteWriter(identityStore: identityStore, databaseWriter: databaseWriter),
            databaseWriter: databaseWriter
        )
    }

    func conversationPermissionsRepository() -> any ConversationPermissionsRepositoryProtocol {
        ConversationPermissionsRepository(inboxStateManager: inboxStateManager,
                                          databaseReader: databaseReader)
    }

    func uploadImage(data: Data, filename: String) async throws -> String {
        let result = try await inboxStateManager.waitForInboxReadyResult()
        return try await result.apiClient.uploadAttachment(
            data: data,
            filename: filename,
            contentType: "image/jpeg",
            acl: "public-read"
        )
    }

    func uploadImageAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String {
        let result = try await inboxStateManager.waitForInboxReadyResult()
        return try await result.apiClient.uploadAttachmentAndExecute(
            data: data,
            filename: filename,
            afterUpload: afterUpload
        )
    }

    func setConversationNotificationsEnabled(_ enabled: Bool, for conversationId: String) async throws {
        let result = try await inboxStateManager.waitForInboxReadyResult()
        let topic = conversationId.xmtpGroupTopicFormat
        let localStateWriter = conversationLocalStateWriter()

        if enabled {
            let deviceId = DeviceInfo.deviceIdentifier
            try await result.apiClient.subscribeToTopics(
                deviceId: deviceId,
                clientId: clientId,
                topics: [topic]
            )
        } else {
            try await result.apiClient.unsubscribeFromTopics(
                clientId: clientId,
                topics: [topic]
            )
        }

        try await localStateWriter.setMuted(!enabled, for: conversationId)
    }
}
