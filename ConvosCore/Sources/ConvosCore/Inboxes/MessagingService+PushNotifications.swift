import Combine
import Foundation
import GRDB
import UniformTypeIdentifiers
import UserNotifications
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
        let inboxReadyResult = try await sessionStateManager.waitForInboxReadyResult()

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

            Log.debug("Handling welcome message notification (no encrypted content)")
            return try await handleWelcomeMessage(
                contentTopic: contentTopic,
                client: client,
                apiClient: apiClient,
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
            client: client,
            apiClient: apiClient
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
        apiClient: any ConvosAPIClientProtocol,
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
        _ = try await client.conversationsProvider.syncAllConversations(consentStates: [.unknown])

        // The pairing DM is a brand-new conversation, so a pairing join
        // request's first delivery is this welcome push. Detect it before
        // anything else can return - the joiner only waits a few minutes,
        // and with no topic subscription for the new DM there may be no
        // second push. Detection has no side effects; the invite
        // processing below still runs either way.
        let pairingRequest = await detectRecentPairingJoinRequest(client: client)

        // Case 1: Process join requests (others accepting our invites)
        let joinRequestOutcomes = await joinRequestsManager.processJoinRequestOutcomes(since: lastProcessed, client: client)
        await handleJoinRequestOutcomesForPush(
            joinRequestOutcomes,
            client: client,
            apiClient: apiClient,
            context: "welcome"
        )

        if let pairingRequest {
            // Only let a genuinely surfaced pairing request take the
            // banner. The scan spans all recent DMs, not just this push's
            // topic, so a deduped duplicate (.droppedMessage) might belong
            // to an earlier push - returning it here would suppress a
            // join-result or new-group notification this same push
            // legitimately carries. On a duplicate, fall through instead.
            let notification = pairingRequestNotification(pairingRequest, userInfo: userInfo)
            if !notification.isDroppedMessage {
                // The join-result / new-group handling still must run to
                // completion: its state writes (setLastWelcomeProcessed,
                // the GRDB bridge for a new group) can't be deferred to a
                // later push, which would no longer see either event as
                // new. Only the banner is superseded. A failure in that
                // pass shouldn't cost the pairing banner, hence the catch.
                do {
                    _ = try await welcomeOutcomeNotification(
                        joinRequestOutcomes: joinRequestOutcomes,
                        existingGroupIds: existingGroupIds,
                        processTime: processTime,
                        client: client,
                        userInfo: userInfo
                    )
                } catch {
                    Log.error("Welcome outcome handling failed after pairing detection: \(error.localizedDescription)")
                }
                return notification
            }
        }

        return try await welcomeOutcomeNotification(
            joinRequestOutcomes: joinRequestOutcomes,
            existingGroupIds: existingGroupIds,
            processTime: processTime,
            client: client,
            userInfo: userInfo
        )
    }

    /// The join-result ("accepted your invite") or new-group ("invite was
    /// verified") notification for this welcome push, running the state
    /// writes that go with each. Factored out of `handleWelcomeMessage` so
    /// the pairing-request path can run it for its side effects while
    /// keeping the pairing banner.
    private func welcomeOutcomeNotification(
        joinRequestOutcomes: [InviteJoinRequestOutcome],
        existingGroupIds: Set<String>,
        processTime: Date,
        client: any XMTPClientProvider,
        userInfo: [AnyHashable: Any]
    ) async throws -> DecodedNotificationContent? {
        if let result = joinRequestOutcomes.compactMap(\.result).first {
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

                // The user deleted this conversation while the invite was
                // still verifying -- it arrived denied and is filtered out
                // of the list, so don't announce it.
                guard dbConversation.consent != .denied else {
                    Log.info("Suppressing welcome notification for denied conversation \(dbConversation.id)")
                    return .droppedMessage
                }

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
                if await isLocallyDeniedInvite(group: newGroup.group) {
                    return .droppedMessage
                }
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

    private func handleJoinRequestOutcomeForPush(
        _ outcome: InviteJoinRequestOutcome,
        client: any XMTPClientProvider,
        apiClient: any ConvosAPIClientProtocol,
        context: String
    ) async {
        await handleJoinRequestOutcomesForPush([outcome], client: client, apiClient: apiClient, context: context)
    }

    private func handleJoinRequestOutcomesForPush(
        _ outcomes: [InviteJoinRequestOutcome],
        client: any XMTPClientProvider,
        apiClient: any ConvosAPIClientProtocol,
        context: String
    ) async {
        guard !outcomes.isEmpty else { return }
        var dmsToSub: [String] = []
        var dmsToUnsub: [String] = []
        var acceptedGroups: [String] = []
        for outcome in outcomes {
            if let dmId = outcome.dmConversationId {
                if outcome.shouldKeepDMSubscribed {
                    dmsToSub.append(dmId)
                } else if case .malicious = outcome {
                    dmsToUnsub.append(dmId)
                }
            }
            if let result = outcome.result {
                acceptedGroups.append(result.conversationId)
            }
        }
        guard !dmsToSub.isEmpty || !dmsToUnsub.isEmpty || !acceptedGroups.isEmpty else { return }
        let params = SyncClientParams(client: client, apiClient: apiClient)
        let mgr = PushTopicSubscriptionManager(identityStore: identityStore, deviceInfoProvider: deviceInfoProvider)
        await mgr.subscribeToInviteDMTopics(conversationIds: dmsToSub, params: params, context: "NSE \(context)")
        await mgr.unsubscribeFromInviteDMTopics(conversationIds: dmsToUnsub, params: params, context: "NSE \(context)")
        await mgr.subscribeToGroupsAndWelcome(conversationIds: acceptedGroups, params: params, context: "NSE \(context) accepted join")
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
        let group: XMTPiOS.Group
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

        for group in currentGroups where !existingGroupIds.contains(group.id) {
            let creatorInboxId = try await group.creatorInboxId()
            if creatorInboxId != client.inboxId {
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
        client: any XMTPClientProvider,
        apiClient: any ConvosAPIClientProtocol
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
                Log.debug("Dropping DM notification - message from self")
                return .droppedMessage
            }

            // A pairing join request (the joiner re-sends every few
            // seconds while connecting) - surface "<device> is requesting
            // to pair" instead of feeding it to the invite flow.
            if let identity = try? identityStore.loadSync(),
               let pairingRequest = PairingJoinRequestDetector.verifiedJoinRequest(in: decodedMessage, identity: identity) {
                return pairingRequestNotification(pairingRequest, userInfo: userInfo)
            }

            // DMs are only used for join requests (invite acceptance flow)
            // When someone accepts an invite, they send the signed invite back via DM
            // This allows us to add them to the group conversation they were invited to
            let joinRequestsManager = InviteJoinRequestsManager(
                identityStore: identityStore,
                databaseWriter: databaseWriter
            )

            let outcome = await joinRequestsManager.processJoinRequestOutcome(message: decodedMessage, client: client)
            await handleJoinRequestOutcomeForPush(outcome, client: client, apiClient: apiClient, context: "encrypted DM")

            if let result = outcome.result {
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
        guard let encodedContentType else {
            return .droppedMessage
        }

        if decodedMessage.isProfileMessage {
            let dbConversation = try await storeConversation(group, inboxId: currentInboxId)
            await processProfileMessageInNSE(decodedMessage, conversationId: dbConversation.id, group: group, currentInboxId: currentInboxId)
            return .droppedMessage
        }

        if let contentType = try? decodedMessage.encodedContent.type,
           contentType == ContentTypeAgentJoinRequest {
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

        // Second line of defense behind the app-side leave/removed unsubscribe:
        // suppress the banner when the local conversation says the user is no
        // longer in it. Mirrors the denied-welcome guard above, and covers the
        // in-flight-push race (a push already sent before the backend
        // unsubscribe landed) plus the removed-but-still-`.allowed` kick case
        // that the reconcile desired set never drops.
        if try await shouldDropGroupNotification(
            conversationId: dbConversation.id,
            consent: dbConversation.consent,
            currentInboxId: currentInboxId
        ) {
            return .droppedMessage
        }

        _ = try await messageWriter.store(message: decodedMessage, for: dbConversation)

        let notificationTitle = (try? await getComputedDisplayName(
            conversationId: conversationId,
            currentInboxId: currentInboxId
        )) ?? (try? group.name()).orUntitled

        let senderName = try await getMemberDisplayName(
            inboxId: decodedMessage.senderInboxId,
            conversationId: conversationId
        )

        let otherMemberCount = try await getOtherMemberCount(
            conversationId: conversationId,
            currentInboxId: currentInboxId
        )
        let body = try await buildNotificationBody(
            encodedContentType: encodedContentType,
            decodedMessage: decodedMessage,
            conversationId: conversationId,
            senderName: senderName,
            otherMemberCount: otherMemberCount
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

    private func getOtherMemberCount(
        conversationId: String,
        currentInboxId: String
    ) async throws -> Int {
        try await databaseReader.read { db in
            try Self.otherMemberCount(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId
            )
        }
    }

    private func shouldDropGroupNotification(
        conversationId: String,
        consent: Consent,
        currentInboxId: String
    ) async throws -> Bool {
        try await databaseReader.read { db in
            try Self.shouldDropGroupNotification(
                db: db,
                conversationId: conversationId,
                consent: consent,
                currentInboxId: currentInboxId
            )
        }
    }

    /// True when a group push should be suppressed because the local state says
    /// the user is no longer in the conversation: the user left (consent
    /// `.denied`), was removed (`ConversationLocalState.wasRemoved`), or the
    /// current inbox is absent from `DBConversationMember` (robust to the kick
    /// path, which sets `wasRemoved` but leaves consent untouched). The
    /// membership read mirrors `otherMemberCount` / `computedDisplayName`,
    /// which already gate on `DBConversationMember` in this file.
    static func shouldDropGroupNotification(
        db: Database,
        conversationId: String,
        consent: Consent,
        currentInboxId: String
    ) throws -> Bool {
        if consent == .denied {
            return true
        }

        let wasRemoved = try ConversationLocalState
            .filter(ConversationLocalState.Columns.conversationId == conversationId)
            .fetchOne(db)?
            .wasRemoved ?? false
        if wasRemoved {
            return true
        }

        let isCurrentMember = try DBConversationMember
            .filter(DBConversationMember.Columns.conversationId == conversationId)
            .filter(DBConversationMember.Columns.inboxId == currentInboxId)
            .fetchCount(db) > 0
        return !isCurrentMember
    }

    /// Counts the conversation's current members excluding the current user,
    /// gated on `DBConversationMember` so a removed member's orphaned profile
    /// no longer inflates the count that drives sender-name prefixing.
    static func otherMemberCount(
        db: Database,
        conversationId: String,
        currentInboxId: String
    ) throws -> Int {
        try DBConversationMember
            .filter(DBConversationMember.Columns.conversationId == conversationId)
            .filter(DBConversationMember.Columns.inboxId != currentInboxId)
            .fetchCount(db)
    }

    private func buildNotificationBody(
        encodedContentType: ContentTypeID,
        decodedMessage: DecodedMessage,
        conversationId: String,
        senderName: String,
        otherMemberCount: Int
    ) async throws -> String? {
        let shouldShowSenderName = otherMemberCount > 1
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
            let emoji = reaction.emoji
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
            if let agentBody = try await agentMadeThingNotificationBody(
                decodedMessage: decodedMessage,
                conversationId: conversationId,
                senderName: senderName,
                otherMemberCount: otherMemberCount
            ) {
                return agentBody
            }
            let attachmentText = try attachmentNotificationText(for: decodedMessage)
            return shouldShowSenderName ? "\(senderName) sent \(attachmentText)" : "sent \(attachmentText)"

        default:
            return nil
        }
    }

    /// Returns the bespoke notification body for an agent sending a single
    /// html file ("made you a thing" / "made a thing for the group"), or nil
    /// when the message should use the generic attachment copy.
    private func agentMadeThingNotificationBody(
        decodedMessage: DecodedMessage,
        conversationId: String,
        senderName: String,
        otherMemberCount: Int
    ) async throws -> String? {
        guard isHtmlFilename(try singleAttachmentFilename(for: decodedMessage)) else {
            return nil
        }
        guard try await isMemberAgent(
            inboxId: decodedMessage.senderInboxId,
            conversationId: conversationId
        ) else {
            return nil
        }
        return otherMemberCount > 1
            ? "\(senderName) made a thing for the group"
            : "\(senderName) made you a thing"
    }

    private func singleAttachmentFilename(for decodedMessage: DecodedMessage) throws -> String? {
        let content = try decodedMessage.content() as Any
        if let attachment = content as? RemoteAttachment {
            return attachment.filename
        }
        if let attachments = content as? [RemoteAttachment], attachments.count == 1 {
            return attachments.first?.filename
        }
        return nil
    }

    private func isHtmlFilename(_ filename: String?) -> Bool {
        guard let filename else { return false }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let utType = UTType(filenameExtension: ext) else { return false }
        return utType.conforms(to: .html)
    }

    private func isMemberAgent(inboxId: String, conversationId: String) async throws -> Bool {
        try await databaseReader.read { db in
            let profile = try DBProfile.fetchOne(db, inboxId: inboxId)
            return profile?.memberKind?.isAgent ?? false
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
            let senderName = try await getMemberDisplayName(
                inboxId: decodedMessage.senderInboxId,
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
        group: XMTPiOS.Group,
        currentInboxId: String
    ) async {
        guard let contentType = try? message.encodedContent.type else { return }

        if contentType == ContentTypeProfileUpdate {
            await processProfileUpdateInNSE(message, conversationId: conversationId, group: group, currentInboxId: currentInboxId)
        } else if contentType == ContentTypeProfileSnapshot {
            await processProfileSnapshotInNSE(message, conversationId: conversationId, group: group, currentInboxId: currentInboxId)
        }
    }

    private func processProfileUpdateInNSE(
        _ message: DecodedMessage,
        conversationId: String,
        group: XMTPiOS.Group,
        currentInboxId: String
    ) async {
        guard let update = try? ProfileUpdateCodec().decode(content: message.encodedContent) else { return }
        let receivedAt = message.sentAt
        let senderInboxId = message.senderInboxId
        guard !senderInboxId.isEmpty else { return }

        do {
            try await databaseWriter.write { db in
                let metadata = update.profileMetadata
                try ProfileInboundApplier.apply(
                    db: db,
                    conversationId: conversationId,
                    event: ProfileInboundApplier.Incoming(
                        inboxId: senderInboxId,
                        source: .profileUpdate,
                        name: update.hasName ? update.name : nil,
                        avatar: .addressed(update.hasEncryptedImage ? update.encryptedImage : nil),
                        memberKind: update.memberKind.dbMemberKind,
                        // Authoritative whole map; empty propagates as a clear
                        // (matches the stream path).
                        metadata: metadata,
                        receivedAt: receivedAt
                    ),
                    selfInboxId: currentInboxId,
                    fallbackEncryptionKey: try DBConversation.fetchOne(db, id: conversationId)?.imageEncryptionKey
                )
            }
            Log.debug("NSE: Processed ProfileUpdate from \(senderInboxId) in \(conversationId)")
        } catch {
            Log.warning("NSE: Failed to process ProfileUpdate: \(error.localizedDescription)")
        }
    }

    private func processProfileSnapshotInNSE(
        _ message: DecodedMessage,
        conversationId: String,
        group: XMTPiOS.Group,
        currentInboxId: String
    ) async {
        guard let snapshot = try? ProfileSnapshotCodec().decode(content: message.encodedContent) else { return }
        // Use the message's authored timestamp, not wall-clock `Date()`.
        // Mirrors the foreground `processProfileSnapshot` and the NSE update path.
        let receivedAt = message.sentAt

        do {
            try await databaseWriter.write { db in
                let fallbackKey = try DBConversation.fetchOne(db, id: conversationId)?.imageEncryptionKey
                for memberProfile in snapshot.profiles {
                    let inboxId = memberProfile.inboxIdString
                    guard !inboxId.isEmpty else { continue }
                    let metadata = memberProfile.profileMetadata
                    try ProfileInboundApplier.apply(
                        db: db,
                        conversationId: conversationId,
                        event: ProfileInboundApplier.Incoming(
                            inboxId: inboxId,
                            source: .profileSnapshot,
                            name: memberProfile.hasName ? memberProfile.name : nil,
                            avatar: .fillIfPresent(memberProfile.hasEncryptedImage ? memberProfile.encryptedImage : nil),
                            memberKind: memberProfile.memberKind.dbMemberKind,
                            metadata: metadata.isEmpty ? nil : metadata,
                            receivedAt: receivedAt
                        ),
                        selfInboxId: currentInboxId,
                        fallbackEncryptionKey: fallbackKey
                    )
                }
            }
            Log.debug("NSE: Processed ProfileSnapshot with \(snapshot.profiles.count) profiles in \(conversationId)")
        } catch {
            Log.warning("NSE: Failed to process ProfileSnapshot: \(error.localizedDescription)")
        }
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
            messageWriter: messageWriter,
            contactSyncCoordinator: ContactSyncCoordinator(
                databaseWriter: databaseWriter,
                databaseReader: databaseReader
            ),
            coreActions: coreActions
        )
        return try await conversationWriter.storeWithLatestMessages(conversation: conversation, inboxId: inboxId)
    }

    /// True when the local DB carries a denial for this group -- either its
    /// own row or a deleted pending-invite draft sharing its invite tag
    /// (the draft survives when storing the arriving group fails). Used to
    /// suppress notifications for conversations the user deleted.
    private func isLocallyDeniedInvite(group: XMTPiOS.Group) async -> Bool {
        let groupId = group.id
        let inviteTag = (try? group.inviteTag) ?? ""
        let denied = try? await databaseReader.read { db in
            var request = DBConversation
                .filter(DBConversation.Columns.consent == Consent.denied)
            if inviteTag.isEmpty {
                request = request.filter(DBConversation.Columns.id == groupId)
            } else {
                request = request.filter(
                    DBConversation.Columns.id == groupId
                        || DBConversation.Columns.inviteTag == inviteTag
                )
            }
            return try request.fetchOne(db) != nil
        }
        return denied ?? false
    }

    // MARK: - Computed Display Name

    private func getComputedDisplayName(
        conversationId: String,
        currentInboxId: String
    ) async throws -> String {
        try await databaseReader.read { db in
            try Self.computedDisplayName(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId
            )
        }
    }

    /// Builds the group notification title from the conversation's current
    /// members. Current membership is read through `DBConversationMember` so a
    /// removed member's orphaned `DBMemberProfile` row no longer feeds the
    /// title; this mirrors the in-app header, which hydrates from
    /// `DBConversationMember` as well. Per-member name resolution still goes
    /// through `ContactsRepository` then the per-conversation profile name.
    static func computedDisplayName(
        db: Database,
        conversationId: String,
        currentInboxId: String
    ) throws -> String {
        guard let conversation = try DBConversation.fetchOne(db, key: conversationId) else {
            return "Untitled"
        }

        if let name = conversation.name, !name.isEmpty {
            return name
        }

        let currentMemberInboxIds = try DBConversationMember
            .filter(DBConversationMember.Columns.conversationId == conversationId)
            .filter(DBConversationMember.Columns.inboxId != currentInboxId)
            .fetchAll(db)
            .map(\.inboxId)

        if currentMemberInboxIds.isEmpty {
            return "New Convo"
        }

        let profilesByInbox: [String: DBProfile] = try DBProfile
            .filter(currentMemberInboxIds.contains(DBProfile.Columns.inboxId))
            .fetchAll(db)
            .reduce(into: [:]) { $0[$1.inboxId] = $1 }

        if profilesByInbox.isEmpty {
            return "New Convo"
        }

        // Resolve each member like `Profile.formattedNamesString(memberNameOverride:)`:
        // the contact's display name (the user's global profile snapshot
        // for this inbox) wins over the canonical profile name.
        // Unnamed members are bucketed by agent vs. human so the rendered
        // title matches: anonymous agents read as "Agent" / "Agents",
        // anonymous humans as "Somebody" / "Somebodies".
        let resolved: [(name: String?, isAgent: Bool)] = try currentMemberInboxIds.map { inboxId -> (name: String?, isAgent: Bool) in
            let profile = profilesByInbox[inboxId]
            let isAgent = profile?.memberKind?.isAgent ?? false
            if let contactName = try ContactsRepository.contactNameInTransaction(db: db, inboxId: inboxId) {
                return (contactName, isAgent)
            }
            if let name = profile?.name, !name.isEmpty {
                return (name, isAgent)
            }
            return (nil, isAgent)
        }
        let namedProfiles: [String] = resolved.compactMap { $0.name }.sorted()
        let anonymousAgentCount: Int = resolved.filter { $0.name == nil && $0.isAgent }.count
        let anonymousHumanCount: Int = resolved.filter { $0.name == nil && !$0.isAgent }.count

        var allNames = namedProfiles
        if anonymousAgentCount == 1 {
            allNames.append("Agent")
        } else if anonymousAgentCount > 1 {
            allNames.append("Agents")
        }
        if anonymousHumanCount == 1 {
            allNames.append("Somebody")
        } else if anonymousHumanCount > 1 {
            allNames.append("Somebodies")
        }

        if allNames.isEmpty {
            return "Untitled"
        }

        return allNames.joined(separator: ", ")
    }

    private func getMemberDisplayName(
        inboxId: String,
        conversationId: String
    ) async throws -> String {
        try await databaseReader.read { db in
            try Self.notificationMemberDisplayName(db: db, inboxId: inboxId, conversationId: conversationId)
        }
    }

    /// Resolves the name shown for a member in notification text, mirroring
    /// `Profile.formattedNamesString(memberNameOverride:)`: the contact's
    /// display name (the user's global profile snapshot for this inbox) wins
    /// over the per-conversation profile name, and nameless members fall back
    /// to "Agent" / "Somebody" keyed on the profile's agent flag.
    static func notificationMemberDisplayName(
        db: Database,
        inboxId: String,
        conversationId: String
    ) throws -> String {
        if let contactName = try ContactsRepository.contactNameInTransaction(db: db, inboxId: inboxId) {
            return contactName
        }
        let profile = try DBProfile.fetchOne(db, inboxId: inboxId)
        if let name = profile?.name, !name.isEmpty { return name }
        // Mirror `Profile.displayName`: known agents read as "Agent",
        // unknown / human profiles read as "Somebody".
        return profile?.memberKind?.isAgent == true ? "Agent" : "Somebody"
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

// MARK: - Pairing Join Requests

extension MessagingService {
    /// Scans recently created unknown-consent DMs for a verified pairing
    /// join request (see `PairingJoinRequestDetector` for the security
    /// model). Used by the welcome-push path, where the request's content
    /// isn't in the payload - the pairing DM was just synced from the
    /// network. Bounded to a handful of fresh DMs and their latest
    /// messages so it stays cheap inside the NSE's time budget.
    func detectRecentPairingJoinRequest(client: any XMTPClientProvider) async -> VerifiedPairingJoinRequest? {
        guard let identity = try? identityStore.loadSync() else { return nil }
        let cutoff = Date().addingTimeInterval(-PairingPushConstant.requestWindow)
        let cutoffNs = Int64(cutoff.timeIntervalSince1970 * 1_000_000_000)
        let dms: [Dm]
        do {
            dms = try client.conversationsProvider.listDms(
                createdAfterNs: cutoffNs,
                createdBeforeNs: nil,
                lastActivityBeforeNs: nil,
                lastActivityAfterNs: nil,
                limit: PairingPushConstant.maxScannedDms,
                consentStates: [.unknown],
                orderBy: .createdAt
            )
        } catch {
            Log.warning("NSE: failed to list DMs for pairing scan: \(error)")
            return nil
        }
        for dm in dms {
            let messages = (try? await dm.messages(limit: PairingPushConstant.maxScannedMessagesPerDm)) ?? []
            for message in messages {
                if let request = PairingJoinRequestDetector.verifiedJoinRequest(in: message, identity: identity) {
                    return request
                }
            }
        }
        return nil
    }

    /// Builds the "<device> is requesting to pair" notification and
    /// stashes the request for the main app to present on next activation
    /// (`PendingPairRequestStore`). The stash doubles as the dedupe
    /// record: the joiner re-sends its request every few seconds, and one
    /// banner per burst is plenty.
    func pairingRequestNotification(
        _ request: VerifiedPairingJoinRequest,
        userInfo: [AnyHashable: Any]
    ) -> DecodedNotificationContent {
        let appGroup = environment.appGroupIdentifier
        // Same replay guard as the stream fast path
        // (`StreamProcessor.handlePairingJoinRequestFastPath`): the ledger
        // is app-group backed, so a nonce already bound to the legitimate
        // joiner rejects a different inbox replaying a captured slug even
        // though this extension is a fresh process per push. The re-decode
        // cannot fail: the detector just verified the slug.
        guard let invite = try? PairingInvite.fromURLSafeSlug(request.slug) else { return .droppedMessage }
        if let boundJoiner = PairingNonceLedger.shared.joiner(for: invite.nonce),
           boundJoiner != request.joinerInboxId {
            Log.warning("NSE: ignoring pairing join request replaying another joiner's slug")
            return .droppedMessage
        }
        PairingNonceLedger.shared.bind(nonce: invite.nonce, toJoiner: request.joinerInboxId)
        if let existing = PendingPairRequestStore.pending(appGroup: appGroup),
           existing.joinerInboxId == request.joinerInboxId,
           Date().timeIntervalSince(existing.receivedAt) < PairingPushConstant.dedupeWindow {
            Log.debug("NSE: suppressing duplicate pairing request notification")
            return .droppedMessage
        }
        PendingPairRequestStore.setPending(
            .init(
                joinerInboxId: request.joinerInboxId,
                deviceName: request.deviceName,
                receivedAt: Date()
            ),
            appGroup: appGroup
        )
        Log.info("NSE: surfacing pairing join request from \(request.joinerInboxId)")
        // The conversationId becomes the notification's threadIdentifier.
        // Stamping the fixed pairing thread lets the system collapse a
        // resend burst's banners and lets the app's activation cleanup
        // find and remove NSE-posted ones (whose request identifiers are
        // system-assigned and unknowable here).
        return .init(
            title: "Pair new device",
            body: "\"\(request.deviceName)\" is requesting to pair",
            conversationId: PairingNotificationThread.identifier,
            userInfo: userInfo
        )
    }

    private enum PairingPushConstant {
        /// How far back a DM can have been created and still be scanned;
        /// matches the joiner's resend window.
        static let requestWindow: TimeInterval = 300
        /// One banner per request burst: the joiner re-sends every ~5s,
        /// and each NSE invocation is a fresh process, so dedupe lives in
        /// the app-group stash rather than memory.
        static let dedupeWindow: TimeInterval = 60
        static let maxScannedDms: Int = 10
        static let maxScannedMessagesPerDm: Int = 5
    }
}
