import Foundation
import GRDB
import UserNotifications
@preconcurrency import XMTPiOS

// MARK: - Protocol

protocol StreamProcessorProtocol: Actor {
    func processConversation(
        _ conversation: XMTPiOS.Group,
        params: SyncClientParams
    ) async throws

    func processConversation(
        _ conversation: any ConversationSender,
        params: SyncClientParams
    ) async throws

    func processMessage(
        _ message: DecodedMessage,
        params: SyncClientParams,
        activeConversationId: String?
    ) async

    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?)
}

/// Processes conversations and messages from XMTP streams
///
/// StreamProcessor handles the processing of individual conversations and messages
/// received from XMTP streams. It coordinates:
/// - Validating conversation consent states
/// - Storing conversations and messages to the database
/// - Processing join requests from DMs
/// - Managing conversation permissions and metadata
/// - Subscribing to push notification topics
/// - Marking conversations as unread when appropriate
///
/// This processor is used by both SyncingManager (for continuous streaming) and
/// ConversationStateMachine (for processing newly created/joined conversations).
actor StreamProcessor: StreamProcessorProtocol {
    // MARK: - Properties

    private let identityStore: any KeychainIdentityStoreProtocol
    private let conversationWriter: any ConversationWriterProtocol
    private let messageWriter: any IncomingMessageWriterProtocol
    private let localStateWriter: any ConversationLocalStateWriterProtocol
    private let joinRequestsManager: any InviteJoinRequestsManagerProtocol
    private let deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)?
    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader
    private let consentStates: [ConsentState] = [.allowed, .unknown]
    private var inviteJoinErrorHandler: (any InviteJoinErrorHandler)?

    // MARK: - Initialization

    init(
        identityStore: any KeychainIdentityStoreProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil
    ) {
        self.identityStore = identityStore
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.deviceRegistrationManager = deviceRegistrationManager
        self.inviteJoinErrorHandler = nil
        let messageWriter = IncomingMessageWriter(databaseWriter: databaseWriter)
        self.conversationWriter = ConversationWriter(
            identityStore: identityStore,
            databaseWriter: databaseWriter,
            messageWriter: messageWriter
        )
        self.messageWriter = messageWriter
        self.localStateWriter = ConversationLocalStateWriter(databaseWriter: databaseWriter)
        self.joinRequestsManager = InviteJoinRequestsManager(
            identityStore: identityStore,
            databaseReader: databaseReader
        )
    }

    // MARK: - Public Interface

    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) {
        self.inviteJoinErrorHandler = handler
    }

    func processConversation(
        _ conversation: any ConversationSender,
        params: SyncClientParams
    ) async throws {
        guard let group = conversation as? XMTPiOS.Group else {
            Log.warning("Passed type other than Group")
            return
        }
        try await processConversation(group, params: params)
    }

    func processConversation(
        _ conversation: XMTPiOS.Group,
        params: SyncClientParams
    ) async throws {
        guard try await shouldProcessConversation(conversation, params: params) else { return }

        let creatorInboxId = try await conversation.creatorInboxId()
        if creatorInboxId == params.client.inboxId {
            // we created the conversation, update permissions, set inviteTag, and generate encryption key
            try await conversation.ensureInviteTag()
            do {
                try await conversation.ensureImageEncryptionKey()
            } catch {
                Log.warning("Failed to generate image encryption key: \(error). Will retry on first image upload.")
            }
            let permissions = try conversation.permissionPolicySet()
            if permissions.addMemberPolicy != .allow {
                // by default allow all members to invite others
                try await conversation.updateAddMemberPermission(newPermissionOption: .allow)
            }
        }

        Log.info("Syncing conversation: \(conversation.id)")
        try await conversationWriter.storeWithLatestMessages(
            conversation: conversation,
            inboxId: params.client.inboxId
        )

        // Subscribe to push notifications
        await subscribeToConversationTopics(
            conversationId: conversation.id,
            params: params,
            context: "on stream"
        )
    }

    func processMessage(
        _ message: DecodedMessage,
        params: SyncClientParams,
        activeConversationId: String?
    ) async {
        do {
            guard let conversation = try await params.client.conversationsProvider.findConversation(
                conversationId: message.conversationId
            ) else {
                Log.error("Conversation not found for message")
                return
            }

            switch conversation {
            case .dm:
                if let inviteJoinError = decodeInviteJoinError(from: message) {
                    await handleInviteJoinError(inviteJoinError, senderInboxId: message.senderInboxId)
                    return
                }

                _ = await joinRequestsManager.processJoinRequest(
                    message: message,
                    client: params.client
                )
                Log.info("Processed potential join request: \(message.id)")
            case .group(let conversation):
                do {
                    guard try await shouldProcessConversation(conversation, params: params) else {
                        Log.warning("Received invalid group message, skipping...")
                        return
                    }

                    // Store conversation before handling ExplodeSettings so the record exists
                    let dbConversation = try await conversationWriter.store(
                        conversation: conversation,
                        inboxId: params.client.inboxId
                    )

                    // Handle ExplodeSettings - skip storing message if this is an explode message
                    let explodeSettings = messageWriter.decodeExplodeSettings(from: message)
                    if let explodeSettings {
                        await processExplodeSettings(
                            explodeSettings,
                            senderInboxId: message.senderInboxId,
                            conversation: conversation,
                            params: params
                        )
                    }
                    guard explodeSettings == nil else { return }

                    let result = try await messageWriter.store(message: message, for: dbConversation)

                    // Mark unread if needed
                    if result.contentType.marksConversationAsUnread,
                       conversation.id != activeConversationId,
                       message.senderInboxId != params.client.inboxId {
                        try await localStateWriter.setUnread(true, for: conversation.id)
                    }

                    Log.info("Processed message: \(message.id)")
                } catch {
                    Log.error("Failed processing group message: \(error.localizedDescription)")
                }
            }
        } catch {
            Log.warning("Stopped processing message from error: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func decodeInviteJoinError(from message: DecodedMessage) -> InviteJoinError? {
        guard let encodedContentType = try? message.encodedContent.type,
              encodedContentType == ContentTypeInviteJoinError,
              let content = try? message.content() as Any,
              let inviteJoinError = content as? InviteJoinError else {
            return nil
        }
        return inviteJoinError
    }

    private func handleInviteJoinError(_ error: InviteJoinError, senderInboxId: String) async {
        Log.info("Received InviteJoinError (\(error.errorType.rawValue)) for inviteTag: \(error.inviteTag) from \(senderInboxId)")
        await inviteJoinErrorHandler?.handleInviteJoinError(error)
    }

    private func processExplodeSettings(
        _ settings: ExplodeSettings,
        senderInboxId: String,
        conversation: XMTPiOS.Group,
        params: SyncClientParams
    ) async {
        let result = await messageWriter.processExplodeSettings(
            settings,
            conversationId: conversation.id,
            senderInboxId: senderInboxId,
            currentInboxId: params.client.inboxId
        )

        if case .applied = result {
            let conversationName = (try? conversation.name()).orUntitled
            await postExplosionNotification(conversationName: conversationName, conversationId: conversation.id)
        }
    }

    private func postExplosionNotification(conversationName: String, conversationId: String) async {
        let content = UNMutableNotificationContent()
        content.title = "💥 \(conversationName) 💥"
        content.body = "A convo exploded"
        content.sound = .default
        content.userInfo = ["isExplosion": true]
        content.threadIdentifier = conversationId

        let request = UNNotificationRequest(
            identifier: "explosion-\(conversationId)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Log.error("Failed to post explosion notification: \(error.localizedDescription)")
        }
    }

    /// Checks if a conversation should be processed based on its consent state.
    /// If consent is unknown but there's an outgoing join request, updates consent to allowed.
    /// - Parameters:
    ///   - conversation: The conversation to check
    ///   - params: The sync client parameters
    /// - Returns: True if the conversation has allowed consent and should be processed
    private func shouldProcessConversation(
        _ conversation: XMTPiOS.Group,
        params: SyncClientParams
    ) async throws -> Bool {
        var consentState = try conversation.consentState()
        guard consentState != .allowed else {
            return true
        }

        guard try await conversation.creatorInboxId() != params.client.inboxId else {
            return true
        }

        if consentState == .unknown {
            let hasOutgoingJoinRequest = try await joinRequestsManager.hasOutgoingJoinRequest(
                for: conversation,
                client: params.client
            )

            if hasOutgoingJoinRequest {
                try await conversation.updateConsentState(state: .allowed)
                consentState = try conversation.consentState()
            }
        }

        return consentState == .allowed
    }

    // MARK: - Push Notifications

    private func subscribeToConversationTopics(
        conversationId: String,
        params: SyncClientParams,
        context: String
    ) async {
        // Ensure device is registered before subscribing to topics
        // This is a defensive check - the device should already be registered on app launch,
        // but we want to ensure it's registered before we attempt topic subscription
        guard let deviceManager = deviceRegistrationManager else {
            Log.warning("DeviceRegistrationManager not available, skipping topic subscription")
            return
        }

        let conversationTopic = conversationId.xmtpGroupTopicFormat
        let welcomeTopic = params.client.installationId.xmtpWelcomeTopicFormat

        guard let identity = try? await identityStore.identity(for: params.client.inboxId) else {
            Log.warning("Identity not found, skipping push notification subscription")
            return
        }

        await deviceManager.registerDeviceIfNeeded()

        do {
            let deviceId = DeviceInfo.deviceIdentifier
            try await params.apiClient.subscribeToTopics(
                deviceId: deviceId,
                clientId: identity.clientId,
                topics: [conversationTopic, welcomeTopic]
            )
            Log.info("Subscribed to push topics \(context): \(conversationTopic), \(welcomeTopic)")
        } catch {
            Log.warning("Failed subscribing to topics \(context): \(error)")
        }
    }
}
