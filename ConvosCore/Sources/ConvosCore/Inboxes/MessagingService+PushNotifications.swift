import Combine
import Foundation
import GRDB
import XMTPiOS

/// Extension providing push notification specific functionality for SingleInboxAuthProcessor
extension MessagingService {
    /// Processes a push notification when the inbox is ready
    /// - Parameters:
    ///   - payload: The decoded push notification payload
    func processPushNotification(
        payload: PushNotificationPayload
    ) async throws -> DecodedNotificationContent? {
        Log.info("processPushNotification called")
        let inboxReadyResult = try await inboxStateManager.waitForInboxReadyResult()

        return try await self.handlePushNotification(
            inboxReadyResult: inboxReadyResult,
            payload: payload
        )
    }

    /// Handles the actual push notification processing when inbox is ready
    /// - Parameters:
    ///   - inboxReadyResult: The ready inbox with client and API client
    ///   - payload: The decoded push notification payload
    private func handlePushNotification(
        inboxReadyResult: InboxReadyResult,
        payload: PushNotificationPayload
    ) async throws -> DecodedNotificationContent? {
        let client = inboxReadyResult.client
        let apiClient = inboxReadyResult.apiClient

        Log.debug("Processing notification with JWT override: \(payload.apiJWT != nil)")
        Log.debug("Payload notification data: \(payload.notificationData != nil ? "present" : "nil")")

        return try await handleProtocolMessage(
            payload: payload,
            client: client,
            apiClient: apiClient
        )
    }

    /// Handles protocol message notifications
    private func handleProtocolMessage(
        payload: PushNotificationPayload,
        client: any XMTPClientProvider,
        apiClient: any ConvosAPIClientProtocol
    ) async throws -> DecodedNotificationContent? {
        guard let protocolData = payload.notificationData?.protocolData else {
            Log.error("Missing protocol data in notification payload")
            return nil
        }

        guard let contentTopic = protocolData.contentTopic else {
            Log.error("Missing contentTopic in notification payload")
            return nil
        }

        // Welcome messages don't include encrypted content (too large for push)
        let isWelcomeTopic = contentTopic.contains("/w-")

        if protocolData.encryptedMessage == nil {
            // No encrypted content - must be a welcome message
            guard isWelcomeTopic else {
                Log.error("Missing encryptedMessage for non-welcome topic: \(contentTopic)")
                return nil
            }

            Log.info("Handling welcome message notification (no encrypted content)")
            return try await handleWelcomeMessage(
                contentTopic: contentTopic,
                client: client,
                userInfo: payload.userInfo
            )
        }

        // Regular message - decrypt the encrypted content
        guard let encryptedMessage = protocolData.encryptedMessage else {
            Log.error("Missing encryptedMessage after nil check")
            return nil
        }

        let currentInboxId = client.inboxId

        // Try to decode the text message for notification display
        return try await decodeTextMessageWithSender(
            encryptedMessage: encryptedMessage,
            contentTopic: contentTopic,
            currentInboxId: currentInboxId,
            userInfo: payload.userInfo,
            client: client
        )
    }

    /// Handles welcome message notifications by syncing from network
    /// Welcome messages are too large for push notifications, so we sync from XMTP network
    ///
    /// Welcome messages are received in two scenarios:
    /// 1. Someone accepted our invite (they sent us a DM with signed invite, we add them to group)
    /// 2. We were added to a group (after we sent a join request DM to an inviter)
    ///
    /// This handler processes both cases: join requests from others and detecting new groups we've joined.
    private func handleWelcomeMessage(
        contentTopic: String,
        client: any XMTPClientProvider,
        userInfo: [AnyHashable: Any]
    ) async throws -> DecodedNotificationContent? {
        Log.info("Syncing conversations after receiving welcome message")

        // Capture timestamp first to avoid missing messages
        let processTime = Date()

        // Get last processed time
        let lastProcessed = getLastWelcomeProcessed(for: client.inboxId)
        if let lastProcessed {
            Log.info("Last processed welcome message \(lastProcessed.relativeShort()) ago...")
        }

        // Get existing group IDs before sync to detect new groups we've been added to
        let existingGroupIds = try await getExistingGroupIds(client: client)

        let joinRequestsManager = InviteJoinRequestsManager(
            identityStore: identityStore,
            databaseReader: databaseReader
        )

        // Sync all conversations - this will fetch any groups we've been added to
        _ = try await client.conversationsProvider.syncAllConversations(consentStates: [.unknown])

        // Case 1: Process join requests (others accepting our invites)
        let joinRequestResults = await joinRequestsManager.processJoinRequests(since: lastProcessed, client: client)
        if let result = joinRequestResults.first {
            setLastWelcomeProcessed(processTime, for: client.inboxId)
            return .init(
                title: result.conversationName,
                body: "Somebody accepted your invite",
                conversationId: result.conversationId,
                userInfo: userInfo
            )
        }

        // Case 2: Check if we've been added to any new groups (we were the joiner)
        if let newGroup = try await findNewGroupWeJoined(client: client, existingGroupIds: existingGroupIds) {
            Log.info("We were added to a new group: \(newGroup.conversationId)")
            setLastWelcomeProcessed(processTime, for: client.inboxId)
            return .init(
                title: newGroup.conversationName,
                body: "Somebody approved your invite",
                conversationId: newGroup.conversationId,
                userInfo: userInfo
            )
        }

        // No actionable welcome message
        return .droppedMessage
    }

    private func getExistingGroupIds(client: any XMTPClientProvider) async throws -> Set<String> {
        let groups = try client.conversationsProvider.listGroups(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityAfterNs: nil,
            lastActivityBeforeNs: nil,
            limit: nil,
            consentStates: nil,
            orderBy: .createdAt
        )
        return Set(groups.map { $0.id })
    }

    private struct NewGroupInfo {
        let conversationId: String
        let conversationName: String?
    }

    private func findNewGroupWeJoined(
        client: any XMTPClientProvider,
        existingGroupIds: Set<String>
    ) async throws -> NewGroupInfo? {
        let currentGroups = try client.conversationsProvider.listGroups(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityAfterNs: nil,
            lastActivityBeforeNs: nil,
            limit: nil,
            consentStates: [.unknown, .allowed],
            orderBy: .createdAt
        )

        // Find groups that are new (not in our existing set)
        for group in currentGroups where !existingGroupIds.contains(group.id) {
            // Check if we're NOT the creator (meaning we were added)
            let creatorInboxId = try await group.creatorInboxId()
            if creatorInboxId != client.inboxId {
                let name = try? group.name()
                return NewGroupInfo(conversationId: group.id, conversationName: name)
            }
        }

        return nil
    }

    /// Decodes a text message for notification display with sender info
    private func decodeTextMessageWithSender(
        encryptedMessage: String,
        contentTopic: String,
        currentInboxId: String,
        userInfo: [AnyHashable: Any],
        client: any XMTPClientProvider
    ) async throws -> DecodedNotificationContent? {
        // Extract conversation ID from topic path
        guard let conversationId = contentTopic.conversationIdFromXMTPGroupTopic else {
            Log.warning("Unable to extract conversation id from contentTopic: \(contentTopic)")
            return nil
        }

        // Find the conversation
        guard let conversation = try await client.conversationsProvider.findConversation(conversationId: conversationId) else {
            Log.warning("Conversation not found for topic: \(contentTopic), extracted ID: \(conversationId)")
            return nil
        }

        // Decode the encrypted message
        guard let messageBytes = Data(base64Encoded: Data(encryptedMessage.utf8)) else {
            Log.warning("Failed to decode base64 encrypted message")
            return nil
        }

        // Process the message
        guard let decodedMessage = try await conversation.processMessage(messageBytes: messageBytes) else {
            Log.warning("Failed to process message bytes")
            return nil
        }

        switch conversation {
        case .dm:
            // Check if message is from self - DMs from self should be dropped
            if decodedMessage.senderInboxId == currentInboxId {
                Log.info("Dropping DM notification - message from self")
                return .droppedMessage
            }

            // DMs are only used for join requests (invite acceptance flow)
            // When someone accepts an invite, they send the signed invite back via DM
            // This allows us to add them to the group conversation they were invited to
            let joinRequestsManager = InviteJoinRequestsManager(
                identityStore: identityStore,
                databaseReader: databaseReader
            )

            do {
                if let result = try await joinRequestsManager.processJoinRequest(message: decodedMessage, client: client) {
                    // Valid join request - show notification
                    return .init(
                        title: result.conversationName,
                        body: "Somebody accepted your invite",
                        conversationId: result.conversationId,
                        userInfo: userInfo
                    )
                }
            } catch {
                // Not a valid join request - block the DM to prevent spam
                Log.warning("DM is not a valid join request, blocking conversation")
                try? await conversation.updateConsentState(state: .denied)
                return .droppedMessage
            }

            // Shouldn't reach here, but if we do, drop the notification
            return .droppedMessage
        case .group(let group):
            return try await handleGroupMessage(
                group: group,
                decodedMessage: decodedMessage,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                userInfo: userInfo
            )
        }
    }

    private func handleGroupMessage(
        group: XMTPiOS.Group,
        decodedMessage: DecodedMessage,
        conversationId: String,
        currentInboxId: String,
        userInfo: [AnyHashable: Any]
    ) async throws -> DecodedNotificationContent? {
        let messageWriter = IncomingMessageWriter(databaseWriter: databaseWriter)
        let explodeSettings = messageWriter.decodeExplodeSettings(from: decodedMessage)
        if let explodeSettings {
            return try await handleExplodeSettingsMessage(
                decodedMessage: decodedMessage,
                settings: explodeSettings,
                group: group,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                userInfo: userInfo
            )
        }

        if decodedMessage.senderInboxId == currentInboxId {
            return .droppedMessage
        }

        let encodedContentType = try? decodedMessage.encodedContent.type
        guard let encodedContentType, encodedContentType == ContentTypeText else {
            return .droppedMessage
        }

        let dbConversation = try await storeConversation(group, inboxId: currentInboxId)

        _ = try await messageWriter.store(message: decodedMessage, for: dbConversation)

        let content = try decodedMessage.content() as Any
        guard let textContent = content as? String else {
            return .droppedMessage
        }

        let notificationTitle = (try? group.name()).orUntitled

        return .init(
            title: notificationTitle,
            body: textContent,
            conversationId: conversationId,
            userInfo: userInfo
        )
    }

    private func handleExplodeSettingsMessage(
        decodedMessage: DecodedMessage,
        settings: ExplodeSettings,
        group: XMTPiOS.Group,
        conversationId: String,
        currentInboxId: String,
        userInfo: [AnyHashable: Any]
    ) async throws -> DecodedNotificationContent? {
        let messageWriter = IncomingMessageWriter(databaseWriter: databaseWriter)
        let result = await messageWriter.processExplodeSettings(
            settings,
            conversationId: conversationId,
            senderInboxId: decodedMessage.senderInboxId,
            currentInboxId: currentInboxId
        )

        switch result {
        case .applied:
            let conversationName = (try? group.name()).orUntitled
            var explosionUserInfo = userInfo
            explosionUserInfo["isExplosion"] = true
            explosionUserInfo["clientId"] = currentInboxId
            return .init(
                title: "💥 \(conversationName) 💥",
                body: "A convo exploded",
                conversationId: conversationId,
                userInfo: explosionUserInfo
            )
        case .fromSelf, .alreadyExpired:
            return .droppedMessage
        }
    }

    /// Stores a conversation in the database along with its latest messages
    /// This ensures XMTP has complete group state for decrypting subsequent messages
    /// - Parameter conversation: The XMTP conversation to store
    /// - Returns: The stored database conversation
    @discardableResult
    private func storeConversation(_ conversation: XMTPiOS.Group, inboxId: String) async throws -> DBConversation {
        let messageWriter = IncomingMessageWriter(databaseWriter: databaseWriter)
        let conversationWriter = ConversationWriter(
            identityStore: identityStore,
            databaseWriter: databaseWriter,
            messageWriter: messageWriter
        )
        return try await conversationWriter.storeWithLatestMessages(conversation: conversation, inboxId: inboxId)
    }

    // MARK: - Welcome Message Tracking

    private static let lastWelcomeProcessedKeyPrefix: String = "convos.pushNotifications.lastWelcomeProcessed"

    private func getLastWelcomeProcessed(for inboxId: String) -> Date? {
        let key = "\(Self.lastWelcomeProcessedKeyPrefix).\(inboxId)"
        return UserDefaults.standard.object(forKey: key) as? Date
    }

    private func setLastWelcomeProcessed(_ date: Date?, for inboxId: String) {
        let key = "\(Self.lastWelcomeProcessedKeyPrefix).\(inboxId)"
        UserDefaults.standard.set(date, forKey: key)
    }
}
