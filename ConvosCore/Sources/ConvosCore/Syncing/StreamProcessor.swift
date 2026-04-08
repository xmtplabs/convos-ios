import ConvosInvites
import ConvosProfiles
import Foundation
import GRDB
import UserNotifications
@preconcurrency import XMTPiOS

// MARK: - Protocol

protocol StreamProcessorProtocol: Actor {
    func processConversation(
        _ conversation: XMTPiOS.Group,
        params: SyncClientParams,
        clientConversationId: String?
    ) async throws

    func processConversation(
        _ conversation: any ConversationSender,
        params: SyncClientParams,
        clientConversationId: String?
    ) async throws

    func processMessage(
        _ message: DecodedMessage,
        params: SyncClientParams,
        activeConversationId: String?
    ) async

    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?)
}

extension StreamProcessorProtocol {
    func processConversation(
        _ conversation: XMTPiOS.Group,
        params: SyncClientParams
    ) async throws {
        try await processConversation(conversation, params: params, clientConversationId: nil)
    }

    func processConversation(
        _ conversation: any ConversationSender,
        params: SyncClientParams
    ) async throws {
        try await processConversation(conversation, params: params, clientConversationId: nil)
    }
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
    private let notificationCenter: any UserNotificationCenterProtocol
    private let consentStates: [ConsentState] = [.allowed, .unknown]
    private var inviteJoinErrorHandler: (any InviteJoinErrorHandler)?
    private let vaultMessageProcessor: (any VaultMessageProcessorProtocol)?

    // MARK: - Initialization

    init(
        identityStore: any KeychainIdentityStoreProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil,
        vaultMessageProcessor: (any VaultMessageProcessorProtocol)? = nil,
        notificationCenter: any UserNotificationCenterProtocol
    ) {
        self.identityStore = identityStore
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.deviceRegistrationManager = deviceRegistrationManager
        self.vaultMessageProcessor = vaultMessageProcessor
        self.notificationCenter = notificationCenter
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
            databaseWriter: databaseWriter
        )
    }

    // MARK: - Public Interface

    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) {
        self.inviteJoinErrorHandler = handler
    }

    func processConversation(
        _ conversation: any ConversationSender,
        params: SyncClientParams,
        clientConversationId: String? = nil
    ) async throws {
        guard let group = conversation as? XMTPiOS.Group else {
            Log.warning("Passed type other than Group")
            return
        }
        try await processConversation(group, params: params, clientConversationId: clientConversationId)
    }

    func processConversation(
        _ conversation: XMTPiOS.Group,
        params: SyncClientParams,
        clientConversationId: String? = nil
    ) async throws {
        if let vaultProcessor = vaultMessageProcessor,
           await vaultProcessor.isVaultConversation(conversation.id) {
            return
        }

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
            if permissions.addMemberPolicy != .allow && permissions.addMemberPolicy != .deny {
                try await conversation.updateAddMemberPermission(newPermissionOption: .allow)
            }
        }

        let perfStart = CFAbsoluteTimeGetCurrent()
        Log.info("Syncing conversation: \(conversation.id)")
        let dbConversation = try await conversationWriter.storeWithLatestMessages(
            conversation: conversation,
            inboxId: params.client.inboxId,
            clientConversationId: clientConversationId
        )
        let perfElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - perfStart) * 1000)
        Log.info("[PERF] conversation.sync: \(perfElapsed)ms id=\(conversation.id)")

        await reactivateIfNeeded(conversationId: dbConversation.id)

        if creatorInboxId == params.client.inboxId {
            await sendInitialProfileSnapshot(group: conversation)
        }

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
        if let vaultProcessor = vaultMessageProcessor,
           await vaultProcessor.isVaultConversation(message.conversationId) {
            await vaultProcessor.processVaultMessage(message)
            return
        }

        let perfStart = CFAbsoluteTimeGetCurrent()
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
                Log.debug("Processed potential join request: \(message.id)")
            case .group(let conversation):
                do {
                    guard try await shouldProcessConversation(conversation, params: params) else {
                        Log.warning("Received invalid group message, skipping...")
                        return
                    }

                    let dbConversation: DBConversation
                    do {
                        dbConversation = try await conversationWriter.store(
                            conversation: conversation,
                            inboxId: params.client.inboxId
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        Log.warning("conversationWriter.store failed, falling back to existing DBConversation: \(error)")
                        guard let existing = try await databaseReader.read({ db in
                            try DBConversation.fetchOne(db, id: conversation.id)
                        }) else {
                            throw error
                        }
                        dbConversation = existing
                    }

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

                    if await processProfileMessage(message, conversationId: conversation.id) {
                        return
                    }

                    let result = try await messageWriter.store(message: message, for: dbConversation)

                    await markReconnectionIfNeeded(
                        messageId: message.id,
                        conversationId: conversation.id
                    )

                    // Mark unread if needed
                    if result.contentType.marksConversationAsUnread,
                       conversation.id != activeConversationId,
                       message.senderInboxId != params.client.inboxId {
                        try await localStateWriter.setUnread(true, for: conversation.id)
                    }

                    let perfElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - perfStart) * 1000)
                    Log.info("[PERF] message.process: \(perfElapsed)ms id=\(message.id)")
                } catch is CancellationError {
                    // This function is `async` (not `async throws`), so we
                    // cannot rethrow. Log and return early — the enclosing
                    // stream loop calls `try Task.checkCancellation()` at
                    // the top of every iteration, so the task exits on the
                    // next message. One extra in-flight message is acceptable
                    // for cooperative cancellation here.
                    Log.debug("Group message processing cancelled")
                    return
                } catch {
                    Log.error("Failed processing group message: \(error.localizedDescription)")
                }
            }
        } catch is CancellationError {
            Log.debug("Message processing cancelled")
            return
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

    // MARK: - Reactivation

    private func reactivateIfNeeded(conversationId: String) async {
        do {
            let isInactive = try await databaseReader.read { db in
                try ConversationLocalState
                    .filter(ConversationLocalState.Columns.conversationId == conversationId)
                    .filter(ConversationLocalState.Columns.isActive == false)
                    .fetchOne(db) != nil
            }
            guard isInactive else { return }

            try await markRecentUpdatesAsReconnection(conversationId: conversationId)
            try await localStateWriter.setActive(true, for: conversationId)
            Log.info("Reactivated conversation \(conversationId) during sync")
        } catch {
            Log.warning("reactivateIfNeeded failed for \(conversationId): \(error)")
        }
    }

    private func markRecentUpdatesAsReconnection(conversationId: String) async throws {
        try await databaseWriter.write { db in
            let sql = """
                SELECT id FROM message
                WHERE conversationId = ?
                  AND contentType = 'update'
                ORDER BY date DESC
                LIMIT 5
                """
            let messageIds = try String.fetchAll(db, sql: sql, arguments: [conversationId])
            for messageId in messageIds {
                guard var dbMessage = try DBMessage.fetchOne(db, key: messageId),
                      var update = dbMessage.update else { continue }
                if !update.isReconnection {
                    update.isReconnection = true
                    dbMessage = dbMessage.with(update: update)
                    try dbMessage.save(db)
                }
            }
        }
    }

    private func markReconnectionIfNeeded(messageId: String, conversationId: String) async {
        do {
            let isInactive = try await databaseReader.read { db in
                try ConversationLocalState
                    .filter(ConversationLocalState.Columns.conversationId == conversationId)
                    .filter(ConversationLocalState.Columns.isActive == false)
                    .fetchOne(db) != nil
            }
            guard isInactive else { return }

            try await databaseWriter.write { db in
                if var dbMessage = try DBMessage.fetchOne(db, key: messageId),
                   var update = dbMessage.update {
                    update.isReconnection = true
                    dbMessage = dbMessage.with(update: update)
                    try dbMessage.save(db)
                }
            }

            try await localStateWriter.setActive(true, for: conversationId)
            Log.info("Reactivated conversation \(conversationId) after receiving message")
        } catch {
            Log.warning("markReconnectionIfNeeded failed for \(conversationId): \(error)")
        }
    }

    // MARK: - Profile Messages

    private func processProfileMessage(_ message: DecodedMessage, conversationId: String) async -> Bool {
        guard let contentType = try? message.encodedContent.type else {
            return false
        }

        if contentType == ContentTypeProfileUpdate {
            await processProfileUpdate(message, conversationId: conversationId)
            return true
        } else if contentType == ContentTypeProfileSnapshot {
            await processProfileSnapshot(message, conversationId: conversationId)
            return true
        }

        return false
    }

    private func processProfileUpdate(_ message: DecodedMessage, conversationId: String) async {
        guard let update = try? ProfileUpdateCodec().decode(content: message.encodedContent) else {
            Log.warning("Failed to decode ProfileUpdate from message \(message.id)")
            return
        }

        let senderInboxId = message.senderInboxId
        guard !senderInboxId.isEmpty else {
            Log.warning("ProfileUpdate with empty senderInboxId, skipping")
            return
        }
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

                let profileMetadata = update.profileMetadata
                profile = profile.with(metadata: profileMetadata.isEmpty ? nil : profileMetadata)

                try profile.save(db)
            }
            Log.debug("Processed ProfileUpdate from \(senderInboxId) in \(conversationId)")
        } catch {
            Log.error("Failed to process ProfileUpdate: \(error.localizedDescription)")
        }
    }

    private func processProfileSnapshot(_ message: DecodedMessage, conversationId: String) async {
        guard let snapshot = try? ProfileSnapshotCodec().decode(content: message.encodedContent) else {
            Log.warning("Failed to decode ProfileSnapshot from message \(message.id)")
            return
        }

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

                    let snapshotMetadata = memberProfile.profileMetadata
                    profile = profile.with(metadata: snapshotMetadata.isEmpty ? nil : snapshotMetadata)

                    try profile.save(db)
                }
            }
            Log.debug("Processed ProfileSnapshot with \(snapshot.profiles.count) profiles in \(conversationId)")
        } catch {
            Log.error("Failed to process ProfileSnapshot: \(error.localizedDescription)")
        }
    }

    private func sendInitialProfileSnapshot(group: XMTPiOS.Group) async {
        do {
            let allMemberInboxIds = try await group.members.map(\.inboxId)
            try await ProfileSnapshotBuilder.sendSnapshot(
                group: group,
                memberInboxIds: allMemberInboxIds
            )
            Log.debug("Sent initial ProfileSnapshot for \(group.id)")
        } catch {
            Log.warning("Failed to send initial ProfileSnapshot: \(error.localizedDescription)")
        }
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

        let conversationName = (try? conversation.name()).orUntitled

        switch result {
        case .applied:
            await postExplosionNotification(conversationName: conversationName, conversationId: conversation.id)
        case .scheduled(let expiresAt):
            let senderName = await getSenderDisplayName(senderInboxId: senderInboxId, conversationId: conversation.id)
            await postScheduledExplosionNotification(
                senderName: senderName,
                conversationName: conversationName,
                conversationId: conversation.id,
                expiresAt: expiresAt
            )
        case .fromSelf, .alreadyExpired, .unauthorized:
            break
        }
    }

    private func getSenderDisplayName(senderInboxId: String, conversationId: String) async -> String {
        do {
            let profile = try await databaseReader.read { db in
                try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: senderInboxId)
            }
            if let name = profile?.name, !name.isEmpty {
                return name
            }
        } catch {
            Log.error("Failed to get sender display name: \(error.localizedDescription)")
        }
        return "Someone"
    }

    private func postScheduledExplosionNotification(
        senderName: String,
        conversationName: String,
        conversationId: String,
        expiresAt: Date
    ) async {
        let content = UNMutableNotificationContent()
        content.title = "\(senderName) set this convo to explode 💣"
        content.body = "in \(ExplosionDurationFormatter.format(until: expiresAt))"
        content.sound = .default
        content.userInfo = ["isScheduledExplosion": true, "conversationId": conversationId]
        content.threadIdentifier = conversationId

        let request = UNNotificationRequest(
            identifier: "scheduled-explosion-\(conversationId)",
            content: content,
            trigger: nil
        )

        do {
            try await notificationCenter.add(request)
        } catch {
            Log.error("Failed to post scheduled explosion notification: \(error.localizedDescription)")
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
            try await notificationCenter.add(request)
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
            Log.debug("Subscribed to push topics \(context): \(conversationTopic), \(welcomeTopic)")
        } catch {
            Log.warning("Failed subscribing to topics \(context): \(error)")
        }
    }
}
