import Combine
import ConvosMessagingProtocols
import ConvosProfiles
import Foundation
import GRDB
import UniformTypeIdentifiers
import UserNotifications
// FIXME: `@preconcurrency import XMTPiOS` remains because this file
// reaches the wire-layer `XMTPiOS.Group` / `DecodedMessage` directly
// for the welcome / group-message processing helpers. `DecodedMessage`
// cannot be round-tripped through `MessagingMessage` because the value
// type does not retain the native handle. Pull both behind the
// abstraction once `MessagingMessage` carries a native-handle escape
// hatch (or the welcome-processing helpers move into the adapter).
@preconcurrency import XMTPiOS

/// Extension providing push notification specific functionality for SingleInboxAuthProcessor
extension MessagingService {
    /// Processes a push notification when the inbox is ready
    /// - Parameters:
    ///   - payload: The decoded push notification payload
    func processPushNotification(
        payload: PushNotificationPayload
    ) async throws -> DecodedNotificationContent? {
        Log.debug("processPushNotification called")
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
        // The XMTPiOS-typed wire-layer reach (XMTPiOS.Group /
        // DecodedMessage / ProfileSnapshotBuilder) is internal here and
        // bridged via XMTPiOSMessagingGroup +
        // `MessagingConversation.processMessage(bytes:)`.
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
        client: any MessagingClient,
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

            Log.debug("Handling welcome message notification (no encrypted content)")
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
        client: any MessagingClient,
        userInfo: [AnyHashable: Any]
    ) async throws -> DecodedNotificationContent? {
        Log.debug("Syncing conversations after receiving welcome message")

        // Capture timestamp first to avoid missing messages
        let processTime = Date()

        // Get last processed time
        let lastProcessed = getLastWelcomeProcessed(for: client.inboxId)
        if let lastProcessed {
            Log.debug("Last processed welcome message \(lastProcessed.relativeShort()) ago...")
        }

        // Get existing group IDs before sync to detect new groups we've been added to
        let existingGroupIds = try await getExistingGroupIds(client: client)

        let joinRequestsManager = InviteJoinRequestsManager(
            identityStore: identityStore,
            databaseWriter: databaseWriter
        )

        // Sync all conversations - this will fetch any groups we've been added to
        _ = try await client.conversations.syncAll(consentStates: [.unknown])

        // Case 1: Process join requests (others accepting our invites)
        let joinRequestResults = await joinRequestsManager.processJoinRequests(since: lastProcessed, client: client)
        if let result = joinRequestResults.first {
            setLastWelcomeProcessed(processTime, for: client.inboxId)

            let displayName = (try? await getComputedDisplayName(
                conversationId: result.conversationId,
                currentInboxId: client.inboxId
            )) ?? result.conversationName.orUntitled

            let joinerName = (try? await getMemberDisplayName(
                inboxId: result.joinerInboxId,
                conversationId: result.conversationId
            )) ?? "Somebody"

            return .init(
                title: displayName,
                body: "\(joinerName) accepted your invite",
                conversationId: result.conversationId,
                userInfo: userInfo
            )
        }

        // Case 2: Check if we've been added to any new groups (we were the joiner)
        if let newGroup = try await findNewGroupWeJoined(client: client, existingGroupIds: existingGroupIds) {
            Log.info("We were added to a new group: \(newGroup.conversationId)")
            setLastWelcomeProcessed(processTime, for: client.inboxId)

            // Store the conversation to the shared GRDB database so the main app's
            // join flow ValueObservation fires immediately. This bridges the NSE's
            // welcome discovery to the main app without needing polling.
            do {
                let dbConversation = try await storeConversation(newGroup.group, inboxId: client.inboxId)

                let displayName = (try? await getComputedDisplayName(
                    conversationId: dbConversation.id,
                    currentInboxId: client.inboxId
                )) ?? newGroup.conversationName.orUntitled

                return .init(
                    title: displayName,
                    body: "Your invite was verified",
                    conversationId: dbConversation.id,
                    userInfo: userInfo
                )
            } catch {
                Log.error("Failed to store conversation in NSE: \(error.localizedDescription)")
                return .init(
                    title: newGroup.conversationName.orUntitled,
                    body: "Your invite was verified",
                    conversationId: newGroup.conversationId,
                    userInfo: userInfo
                )
            }
        }

        // No actionable welcome message
        return .droppedMessage
    }

    private func getExistingGroupIds(client: any MessagingClient) async throws -> Set<String> {
        let groups = try await client.conversations.listGroups(
            query: MessagingConversationQuery(
                consentStates: nil,
                orderBy: .createdAt
            )
        )
        return Set(groups.map { $0.id })
    }

    private struct NewGroupInfo {
        let group: XMTPiOS.Group
        let conversationId: String
        let conversationName: String?
    }

    private func findNewGroupWeJoined(
        client: any MessagingClient,
        existingGroupIds: Set<String>
    ) async throws -> NewGroupInfo? {
        // List through the abstraction; the XMTPiOS-typed `NewGroupInfo`
        // keeps storing the underlying `XMTPiOS.Group` because the
        // downstream NSE writer chain (storeConversation,
        // processProfileMessageInNSE) is XMTPiOS-typed.
        let currentGroups = try await client.conversations.listGroups(
            query: MessagingConversationQuery(
                consentStates: [.unknown, .allowed],
                orderBy: .createdAt
            )
        )

        for messagingGroup in currentGroups where !existingGroupIds.contains(messagingGroup.id) {
            let creatorInboxId = try await messagingGroup.creatorInboxId()
            if creatorInboxId != client.inboxId {
                guard let xmtpAdapter = messagingGroup as? XMTPiOSMessagingGroup else {
                    Log.warning("findNewGroupWeJoined: non-XMTPiOS group adapter; skipping")
                    continue
                }
                let group = xmtpAdapter.underlyingXMTPiOSGroup
                let name = try? group.name()
                return NewGroupInfo(group: group, conversationId: group.id, conversationName: name)
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
        client: any MessagingClient
    ) async throws -> DecodedNotificationContent? {
        // Extract conversation ID from topic path
        guard let conversationId = contentTopic.conversationIdFromXMTPGroupTopic else {
            Log.warning("Unable to extract conversation id from contentTopic: \(contentTopic)")
            return nil
        }

        // The wire-format `processMessage(bytes:)` lives on the
        // abstraction (XMTPiOSMessagingConversation routes to native
        // processMessage; DTU adapter throws since it has no wire
        // format yet).
        guard let messagingConversation = try await client.conversations
            .find(conversationId: conversationId)
        else {
            Log.warning("Conversation not found for topic: \(contentTopic), extracted ID: \(conversationId)")
            return nil
        }

        // Decode the encrypted message
        guard let messageBytes = Data(base64Encoded: Data(encryptedMessage.utf8)) else {
            Log.warning("Failed to decode base64 encrypted message")
            return nil
        }

        // The NSE chain still consumes XMTPiOS.DecodedMessage downstream
        // (joinRequestsManager.processJoinRequest, codec decoding for
        // body text). Reach the underlying XMTPiOS.Conversation via the
        // adapter to re-use the existing `processMessage(messageBytes:)`
        // path that returns a raw `DecodedMessage`.
        let xmtpConversation: XMTPiOS.Conversation
        switch messagingConversation {
        case .dm(let dm):
            guard let xmtpAdapter = dm as? XMTPiOSMessagingDm else {
                Log.warning("decodeTextMessageWithSender: non-XMTPiOS dm adapter; skipping")
                return nil
            }
            xmtpConversation = .dm(xmtpAdapter.underlyingXMTPiOSDm)
        case .group(let group):
            guard let xmtpAdapter = group as? XMTPiOSMessagingGroup else {
                Log.warning("decodeTextMessageWithSender: non-XMTPiOS group adapter; skipping")
                return nil
            }
            xmtpConversation = .group(xmtpAdapter.underlyingXMTPiOSGroup)
        }

        guard let decodedMessage = try await xmtpConversation.processMessage(messageBytes: messageBytes) else {
            Log.warning("Failed to process message bytes")
            return nil
        }

        switch messagingConversation {
        case .dm:
            // Check if message is from self - DMs from self should be dropped
            if decodedMessage.senderInboxId == currentInboxId {
                Log.debug("Dropping DM notification - message from self")
                return .droppedMessage
            }

            // DMs are only used for join requests (invite acceptance flow)
            // When someone accepts an invite, they send the signed invite back via DM
            // This allows us to add them to the group conversation they were invited to
            let joinRequestsManager = InviteJoinRequestsManager(
                identityStore: identityStore,
                databaseWriter: databaseWriter
            )

            if let result = await joinRequestsManager.processJoinRequest(message: decodedMessage, client: client) {
                let displayName = (try? await getComputedDisplayName(
                    conversationId: result.conversationId,
                    currentInboxId: currentInboxId
                )) ?? result.conversationName.orUntitled

                let joinerName = (try? await getMemberDisplayName(
                    inboxId: result.joinerInboxId,
                    conversationId: result.conversationId
                )) ?? "Somebody"

                return .init(
                    title: displayName,
                    body: "\(joinerName) accepted your invite",
                    conversationId: result.conversationId,
                    userInfo: userInfo
                )
            }

            // Not a valid join request or already processed - drop the notification
            // Note: Invalid requests are already blocked by processJoinRequest
            return .droppedMessage
        case .group(let messagingGroup):
            guard let xmtpAdapter = messagingGroup as? XMTPiOSMessagingGroup else {
                Log.warning("decodeTextMessageWithSender: non-XMTPiOS group adapter; skipping")
                return .droppedMessage
            }
            return try await handleGroupMessage(
                group: xmtpAdapter.underlyingXMTPiOSGroup,
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
        // Writers operate on `MessagingMessage`. Wrap the NSE-side
        // `DecodedMessage` once for all writer-bound calls.
        let messagingMessage = try MessagingMessage(decodedMessage)
        let explodeSettings = messageWriter.decodeExplodeSettings(from: messagingMessage)
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
        guard let encodedContentType else {
            return .droppedMessage
        }

        if decodedMessage.isProfileMessage {
            let dbConversation = try await storeConversation(group, inboxId: currentInboxId)
            await processProfileMessageInNSE(decodedMessage, conversationId: dbConversation.id, group: group)
            return .droppedMessage
        }

        if let contentType = try? decodedMessage.encodedContent.type,
           contentType == ContentTypeAssistantJoinRequest {
            return .droppedMessage
        }

        if decodedMessage.isTypingIndicator {
            return .droppedMessage
        }

        if decodedMessage.isReadReceipt {
            await persistReadReceiptInNSE(decodedMessage, conversationId: conversationId)
            return .droppedMessage
        }

        let dbConversation = try await storeConversation(group, inboxId: currentInboxId)

        _ = try await messageWriter.store(message: messagingMessage, for: dbConversation)

        let notificationTitle = (try? await getComputedDisplayName(
            conversationId: conversationId,
            currentInboxId: currentInboxId
        )) ?? (try? group.name()).orUntitled

        let senderName = try await getSenderDisplayName(
            senderInboxId: decodedMessage.senderInboxId,
            conversationId: conversationId
        )

        let otherMemberCount = try await getOtherMemberCount(
            conversationId: conversationId,
            currentInboxId: currentInboxId
        )
        let shouldShowSenderName = otherMemberCount > 1

        let body = try await buildNotificationBody(
            encodedContentType: encodedContentType,
            decodedMessage: decodedMessage,
            conversationId: conversationId,
            senderName: senderName,
            shouldShowSenderName: shouldShowSenderName
        )

        guard let body else {
            return .droppedMessage
        }

        let isReaction = encodedContentType == ContentTypeReaction || encodedContentType == ContentTypeReactionV2
        return .init(
            title: notificationTitle,
            body: body,
            conversationId: conversationId,
            isReaction: isReaction,
            userInfo: userInfo
        )
    }

    private func getSenderDisplayName(
        senderInboxId: String,
        conversationId: String
    ) async throws -> String {
        try await databaseReader.read { db in
            let profile = try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: senderInboxId)
            return profile?.name ?? "Somebody"
        }
    }

    private func getOtherMemberCount(
        conversationId: String,
        currentInboxId: String
    ) async throws -> Int {
        try await databaseReader.read { db in
            try DBMemberProfile
                .filter(DBMemberProfile.Columns.conversationId == conversationId)
                .filter(DBMemberProfile.Columns.inboxId != currentInboxId)
                .fetchCount(db)
        }
    }

    private func buildNotificationBody(
        encodedContentType: ContentTypeID,
        decodedMessage: DecodedMessage,
        conversationId: String,
        senderName: String,
        shouldShowSenderName: Bool
    ) async throws -> String? {
        switch encodedContentType {
        case ContentTypeText:
            let content = try decodedMessage.content() as Any
            guard let textContent = content as? String else {
                return nil
            }
            return shouldShowSenderName ? "\(senderName): \(textContent)" : textContent

        case ContentTypeReaction, ContentTypeReactionV2:
            let content = try decodedMessage.content() as Any
            guard let reaction = content as? Reaction else {
                return nil
            }
            guard reaction.action == .added else {
                return nil
            }
            let emoji = MessagingReaction(reaction).emoji
            let sourceMessageText = try await getSourceMessageText(messageId: reaction.reference, conversationId: conversationId)
            let sourceText = sourceMessageText.formattedAsReactionSource()
            return shouldShowSenderName ? "\(senderName) \(emoji)'d \(sourceText)" : "\(emoji)'d \(sourceText)"

        case ContentTypeReply:
            let content = try decodedMessage.content() as Any
            guard let reply = content as? Reply else {
                return nil
            }
            if let textContent = reply.content as? String {
                return shouldShowSenderName ? "\(senderName): \(textContent)" : textContent
            }
            return nil

        case ContentTypeRemoteAttachment, ContentTypeMultiRemoteAttachment:
            let attachmentText = try attachmentNotificationText(for: decodedMessage)
            return shouldShowSenderName ? "\(senderName) sent \(attachmentText)" : "sent \(attachmentText)"

        default:
            return nil
        }
    }

    private func attachmentNotificationText(for decodedMessage: DecodedMessage) throws -> String {
        let content = try decodedMessage.content() as Any

        if let attachment = content as? RemoteAttachment {
            return attachmentPreviewLabel(for: attachment.filename)
        }

        if let attachments = content as? [RemoteAttachment] {
            return attachmentsPreviewLabel(for: attachments)
        }

        return "an attachment"
    }

    private func attachmentsPreviewLabel(for attachments: [RemoteAttachment]) -> String {
        guard attachments.count > 1 else {
            return attachmentPreviewLabel(for: attachments.first?.filename)
        }

        let mediaTypes = attachments.map { mediaType(for: $0.filename) }
        if let firstType = mediaTypes.first, mediaTypes.allSatisfy({ $0 == firstType }) {
            switch firstType {
            case .image: return "\(attachments.count) photos"
            case .video: return "\(attachments.count) videos"
            case .audio: return "\(attachments.count) voice memos"
            case .file: return "\(attachments.count) files"
            case .unknown: return "\(attachments.count) attachments"
            }
        }

        return "\(attachments.count) attachments"
    }

    private func attachmentPreviewLabel(for filename: String?) -> String {
        switch mediaType(for: filename) {
        case .image: return "a photo"
        case .video: return "a video"
        case .audio: return "a voice memo"
        case .file: return "a file"
        case .unknown: return "an attachment"
        }
    }

    private func mediaType(for filename: String?) -> MediaType {
        guard let filename else { return .unknown }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let utType = UTType(filenameExtension: ext) else { return .unknown }
        if utType.conforms(to: .image) { return .image }
        if utType.conforms(to: .movie) || utType.conforms(to: .video) { return .video }
        if utType.conforms(to: .audio) { return .audio }
        return .file
    }

    private func getSourceMessageText(messageId: String, conversationId: String) async throws -> String? {
        try await databaseReader.read { db in
            let message = try DBMessage.fetchOne(db, key: messageId)
            guard let message, message.conversationId == conversationId else {
                return nil
            }
            return message.text
        }
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
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let toRemove = delivered
                .filter { $0.request.content.threadIdentifier == conversationId }
                .map { $0.request.identifier }
            if !toRemove.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: toRemove)
            }
            center.removePendingNotificationRequests(withIdentifiers: [
                "explosion-reminder-\(conversationId)",
                "explosion-\(conversationId)"
            ])
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
        case .scheduled(let expiresAt):
            _ = try await storeConversation(group, inboxId: currentInboxId)
            let conversationName = (try? group.name()).orUntitled
            let senderName = try await getSenderDisplayName(
                senderInboxId: decodedMessage.senderInboxId,
                conversationId: conversationId
            )
            let timeUntilExplosion = formatTimeUntilExplosion(expiresAt)

            await scheduleExplosionLocalNotification(
                conversationId: conversationId,
                conversationName: conversationName,
                expiresAt: expiresAt
            )

            let body: String
            if timeUntilExplosion == "soon" {
                body = "\(senderName) set this convo to explode \(timeUntilExplosion) 💣"
            } else {
                body = "\(senderName) set this convo to explode in \(timeUntilExplosion) 💣"
            }

            return .init(
                title: conversationName,
                body: body,
                conversationId: conversationId,
                userInfo: userInfo
            )
        case .fromSelf, .alreadyExpired, .unauthorized:
            return .droppedMessage
        }
    }

    private func formatTimeUntilExplosion(_ expiresAt: Date) -> String {
        let interval = expiresAt.timeIntervalSinceNow
        guard interval > 0 else { return "soon" }

        let totalSeconds = Int(interval)
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60

        if days > 0 {
            if hours > 0 {
                return "\(days)d \(hours)h"
            }
            return "\(days) day\(days == 1 ? "" : "s")"
        } else if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        } else if minutes > 0 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        } else {
            return "less than a minute"
        }
    }

    // MARK: - Read Receipt Processing

    private func persistReadReceiptInNSE(
        _ message: DecodedMessage,
        conversationId: String
    ) async {
        let senderInboxId = message.senderInboxId
        guard !senderInboxId.isEmpty else { return }
        let sentAtNs = message.sentAtNs
        do {
            try await databaseWriter.write { db in
                let existing = try DBConversationReadReceipt
                    .filter(Column("conversationId") == conversationId && Column("inboxId") == senderInboxId)
                    .fetchOne(db)
                if let existing, existing.readAtNs >= sentAtNs {
                    // Newer (or equal) read receipt already stored; skip so an
                    // out-of-order delivery can't roll the timestamp backwards.
                    return
                }
                let receipt = DBConversationReadReceipt(
                    conversationId: conversationId,
                    inboxId: senderInboxId,
                    readAtNs: sentAtNs
                )
                try receipt.save(db, onConflict: .replace)
            }
            Log.debug("NSE: Stored read receipt from \(senderInboxId) in \(conversationId)")
        } catch {
            Log.warning("NSE: Failed to store read receipt: \(error.localizedDescription)")
        }
    }

    // MARK: - Profile Message Processing

    private func processProfileMessageInNSE(
        _ message: DecodedMessage,
        conversationId: String,
        group: XMTPiOS.Group
    ) async {
        guard let contentType = try? message.encodedContent.type else { return }

        if contentType == ContentTypeProfileUpdate {
            await processProfileUpdateInNSE(message, conversationId: conversationId, group: group)
        } else if contentType == ContentTypeProfileSnapshot {
            await processProfileSnapshotInNSE(message, conversationId: conversationId, group: group)
        }
    }

    private func processProfileUpdateInNSE(
        _ message: DecodedMessage,
        conversationId: String,
        group: XMTPiOS.Group
    ) async {
        guard let update = try? ProfileUpdateCodec().decode(content: message.encodedContent) else { return }
        let senderInboxId = message.senderInboxId
        guard !senderInboxId.isEmpty else { return }

        do {
            try await databaseWriter.write { db in
                let member = DBMember(inboxId: senderInboxId)
                try member.save(db)

                var profile = try DBMemberProfile.fetchOne(
                    db,
                    conversationId: conversationId,
                    inboxId: senderInboxId
                ) ?? DBMemberProfile(
                    conversationId: conversationId,
                    inboxId: senderInboxId,
                    name: nil,
                    avatar: nil
                )

                profile = profile.with(name: update.hasName ? update.name : nil)

                if update.hasEncryptedImage, update.encryptedImage.isValid {
                    let encryptionKey: Data? = if let existingKey = profile.avatarKey {
                        existingKey
                    } else {
                        try DBConversation.fetchOne(db, id: conversationId)?.imageEncryptionKey
                    }
                    profile = profile.with(
                        avatar: update.encryptedImage.url,
                        salt: update.encryptedImage.salt,
                        nonce: update.encryptedImage.nonce,
                        key: encryptionKey
                    )
                } else {
                    profile = profile.with(avatar: nil, salt: nil, nonce: nil, key: nil)
                }

                profile = profile.with(memberKind: update.memberKind.dbMemberKind)

                if profile.isAgent {
                    let verification = profile.hydrateProfile().verifyCachedAgentAttestation()
                    profile = profile.with(memberKind: DBMemberKind.from(agentVerification: verification))
                }

                try profile.save(db)
                try Self.markConversationHasVerifiedAssistantIfNeeded(profile: profile, conversationId: conversationId, db: db)
            }
            Log.debug("NSE: Processed ProfileUpdate from \(senderInboxId) in \(conversationId)")
        } catch {
            Log.warning("NSE: Failed to process ProfileUpdate: \(error.localizedDescription)")
        }
    }

    private func processProfileSnapshotInNSE(
        _ message: DecodedMessage,
        conversationId: String,
        group: XMTPiOS.Group
    ) async {
        guard let snapshot = try? ProfileSnapshotCodec().decode(content: message.encodedContent) else { return }

        do {
            try await databaseWriter.write { db in
                let encryptionKey = try DBConversation.fetchOne(db, id: conversationId)?.imageEncryptionKey

                for memberProfile in snapshot.profiles {
                    let inboxId = memberProfile.inboxIdString
                    guard !inboxId.isEmpty else { continue }

                    let member = DBMember(inboxId: inboxId)
                    try member.save(db)

                    let existingProfile = try DBMemberProfile.fetchOne(
                        db,
                        conversationId: conversationId,
                        inboxId: inboxId
                    )

                    if existingProfile?.name != nil || existingProfile?.avatar != nil {
                        continue
                    }

                    var profile = existingProfile ?? DBMemberProfile(
                        conversationId: conversationId,
                        inboxId: inboxId,
                        name: nil,
                        avatar: nil
                    )

                    profile = profile.with(name: memberProfile.hasName ? memberProfile.name : nil)

                    if memberProfile.hasEncryptedImage, memberProfile.encryptedImage.isValid {
                        profile = profile.with(
                            avatar: memberProfile.encryptedImage.url,
                            salt: memberProfile.encryptedImage.salt,
                            nonce: memberProfile.encryptedImage.nonce,
                            key: existingProfile?.avatarKey ?? encryptionKey
                        )
                    }

                    profile = profile.with(memberKind: memberProfile.memberKind.dbMemberKind)

                    if profile.isAgent {
                        let verification = profile.hydrateProfile().verifyCachedAgentAttestation()
                        profile = profile.with(memberKind: DBMemberKind.from(agentVerification: verification))
                    }

                    try profile.save(db)
                    try Self.markConversationHasVerifiedAssistantIfNeeded(profile: profile, conversationId: conversationId, db: db)
                }
            }
            Log.debug("NSE: Processed ProfileSnapshot with \(snapshot.profiles.count) profiles in \(conversationId)")
        } catch {
            Log.warning("NSE: Failed to process ProfileSnapshot: \(error.localizedDescription)")
        }
    }

    private static func markConversationHasVerifiedAssistantIfNeeded(
        profile: DBMemberProfile,
        conversationId: String,
        db: Database
    ) throws {
        guard profile.agentVerification.isConvosAssistant,
              let conversation = try DBConversation.fetchOne(db, id: conversationId),
              !conversation.hasHadVerifiedAssistant else { return }
        try conversation.with(hasHadVerifiedAssistant: true).save(db)
    }

    // MARK: - Conversation Storage

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
        // `conversationWriter` takes `any MessagingGroup`; wrap the
        // raw `XMTPiOS.Group` at the call site.
        return try await conversationWriter.storeWithLatestMessages(
            conversation: XMTPiOSMessagingGroup(xmtpGroup: conversation),
            inboxId: inboxId
        )
    }

    // MARK: - Computed Display Name

    private func getComputedDisplayName(
        conversationId: String,
        currentInboxId: String
    ) async throws -> String {
        try await databaseReader.read { db in
            guard let conversation = try DBConversation.fetchOne(db, key: conversationId) else {
                return "Untitled"
            }

            if let name = conversation.name, !name.isEmpty {
                return name
            }

            let memberProfiles = try DBMemberProfile
                .filter(DBMemberProfile.Columns.conversationId == conversationId)
                .filter(DBMemberProfile.Columns.inboxId != currentInboxId)
                .fetchAll(db)

            if memberProfiles.isEmpty {
                return "New Convo"
            }

            let namedProfiles = memberProfiles.compactMap { $0.name }.filter { !$0.isEmpty }.sorted()
            let anonymousCount = memberProfiles.count - namedProfiles.count

            var allNames = namedProfiles
            if anonymousCount > 1 {
                allNames.append("Somebodies")
            } else if anonymousCount == 1 {
                allNames.append("Somebody")
            }

            if allNames.isEmpty {
                return "Untitled"
            }

            return allNames.joined(separator: ", ")
        }
    }

    private func getMemberDisplayName(
        inboxId: String,
        conversationId: String
    ) async throws -> String {
        try await databaseReader.read { db in
            let profile = try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: inboxId)
            return profile?.name ?? "Somebody"
        }
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

    // MARK: - Scheduled Explosion Notifications

    private enum ExplosionNotificationConstant {
        static let explosionIdentifierPrefix: String = "explosion-"
    }

    private func scheduleExplosionLocalNotification(
        conversationId: String,
        conversationName: String,
        expiresAt: Date
    ) async {
        let timeInterval = expiresAt.timeIntervalSinceNow
        guard timeInterval > 0 else {
            Log.debug("NSE: Skipping explosion notification for \(conversationId), already expired")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = conversationName
        content.body = "💥 Boom! This convo exploded. Its messages and members are gone forever"
        content.sound = .default
        content.userInfo = ["isExplosion": true, "conversationId": conversationId]
        content.threadIdentifier = conversationId

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: timeInterval,
            repeats: false
        )

        let identifier = "\(ExplosionNotificationConstant.explosionIdentifierPrefix)\(conversationId)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            Log.debug("NSE: Scheduled explosion notification for \(conversationId) at \(expiresAt)")
        } catch {
            Log.error("NSE: Failed to schedule explosion notification: \(error.localizedDescription)")
        }
    }
}
