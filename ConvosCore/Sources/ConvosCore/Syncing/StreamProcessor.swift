import ConvosConnections
import ConvosConnectionsXMTP
import ConvosInvites
import ConvosMetrics
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

    func reconcilePushSubscriptions(params: SyncClientParams, context: String) async

    /// Drops every cached push-topic-set hash. Intended for the explicit
    /// "Delete all data" / sign-out path where the caller wants to force the
    /// next reconcile to hit the wire instead of debouncing. Day-to-day
    /// identity rotation is already handled by partitioning the cache key
    /// on inboxId / clientId, so callers should NOT invoke this on every
    /// resume / foreground.
    func clearPushSubscriptionCache() async

    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?)
    func setTypingIndicatorHandler(_ handler: @escaping @Sendable (String, String, Bool) -> Void)
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
    private let pushTopicSubscriptionManager: any PushTopicSubscriptionManaging
    private let thinkingSessionWriter: any ThinkingSessionWriterProtocol
    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader
    private let notificationCenter: any UserNotificationCenterProtocol
    private let inboundFilter: InboundConversationFilter
    private let consentStates: [ConsentState] = [.allowed, .unknown]
    private var inviteJoinErrorHandler: (any InviteJoinErrorHandler)?
    private var onTypingIndicator: ((String, String, Bool) -> Void)?
    private let invocationRuntime: ConnectionInvocationRuntime?

    // MARK: - Initialization

    init(
        identityStore: any KeychainIdentityStoreProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil,
        notificationCenter: any UserNotificationCenterProtocol,
        invocationRuntime: ConnectionInvocationRuntime? = nil,
        coreActions: any CoreActions
    ) {
        self.identityStore = identityStore
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.pushTopicSubscriptionManager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceRegistrationManager: deviceRegistrationManager,
            cache: PushTopicSubscriptionCache(),
            // Closure captures the configured singleton so cache keys partition
            // by the live APNS token. Token rotation forces a miss; the new
            // `.convosPushTokenDidChange` listener (D14) then drives a fresh
            // reconcile through the wire.
            pushTokenProvider: { PushNotificationRegistrar.token }
        )
        self.notificationCenter = notificationCenter
        self.inviteJoinErrorHandler = nil
        self.invocationRuntime = invocationRuntime
        let messageWriter = IncomingMessageWriter(databaseWriter: databaseWriter)
        self.conversationWriter = ConversationWriter(
            identityStore: identityStore,
            databaseWriter: databaseWriter,
            messageWriter: messageWriter,
            contactSyncCoordinator: ContactSyncCoordinator(
                databaseWriter: databaseWriter,
                databaseReader: databaseReader
            ),
            coreActions: coreActions
        )
        self.messageWriter = messageWriter
        self.localStateWriter = ConversationLocalStateWriter(databaseWriter: databaseWriter)
        self.joinRequestsManager = InviteJoinRequestsManager(
            identityStore: identityStore,
            databaseWriter: databaseWriter
        )
        self.thinkingSessionWriter = ThinkingSessionWriter(databaseWriter: databaseWriter)
        self.inboundFilter = InboundConversationFilter()
    }

    // MARK: - Public Interface

    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) {
        self.inviteJoinErrorHandler = handler
    }

    func setTypingIndicatorHandler(_ handler: @escaping @Sendable (String, String, Bool) -> Void) {
        self.onTypingIndicator = handler
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
        let decision = try await decideInboundConversation(conversation, params: params)
        switch decision {
        case .reject:
            return
        case .deliver:
            try await persistDeliveredConversation(
                conversation,
                params: params,
                clientConversationId: clientConversationId
            )
        }
    }

    private func persistDeliveredConversation(
        _ conversation: XMTPiOS.Group,
        params: SyncClientParams,
        clientConversationId: String?
    ) async throws {
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
        let storedConversation = try await conversationWriter.storeWithLatestMessages(
            conversation: conversation,
            inboxId: params.client.inboxId,
            clientConversationId: clientConversationId
        )
        let perfElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - perfStart) * 1000)
        Log.info("[PERF] conversation.sync: \(perfElapsed)ms id=\(conversation.id)")

        // The user deleted this conversation while its invite was still
        // verifying -- it arrived denied and stays hidden, so skip the
        // profile snapshot and don't subscribe its push topic.
        guard storedConversation.consent != .denied else {
            Log.info("Skipping post-store side effects for denied conversation \(conversation.id)")
            return
        }

        if creatorInboxId == params.client.inboxId {
            await sendInitialProfileSnapshot(group: conversation)
        }

        // Subscribe to push notifications
        await pushTopicSubscriptionManager.subscribeToGroupAndWelcome(
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
        if handleDeviceRemovedFastPath(message: message, params: params) { return }

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

                let outcome = await joinRequestsManager.processJoinRequestOutcome(
                    message: message,
                    client: params.client
                )
                await handleJoinRequestOutcome(outcome, params: params, context: "message stream")
                Log.debug("Processed potential join request: \(message.id)")
            case .group(let conversation):
                do {
                    guard try await shouldProcessConversation(conversation, params: params) else {
                        Log.warning("Received invalid group message, skipping...")
                        return
                    }

                    // Short-circuit row-independent events so a catch-up burst of
                    // typing indicators or read receipts doesn't re-save the conversation
                    // row N times for no state change. Read receipts persist to
                    // DBConversationReadReceipt independently; typing indicators don't
                    // write at all. Explode/profile/real-message paths below still
                    // depend on a fresh row, so they stay downstream of store().
                    if processTypingIndicator(message, conversationId: conversation.id, params: params) {
                        return
                    }

                    if await processReadReceipt(message, conversationId: conversation.id, currentInboxId: params.client.inboxId) {
                        return
                    }

                    if await processBuilderBundleManifest(message, conversationId: conversation.id) {
                        return
                    }

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

                    if await processProfileMessage(message, conversationId: conversation.id) {
                        return
                    }

                    if await processThinking(message, conversationId: conversation.id, params: params) {
                        return
                    }

                    await invocationRuntime?.process(
                        message: message,
                        conversationId: conversation.id,
                        client: params.client
                    )

                    let result = try await messageWriter.store(message: message, for: dbConversation)

                    // Mark unread if needed (shared predicate with the
                    // catch-up paths so the gate can't drift).
                    if marksConversationUnread(
                        contentType: result.contentType,
                        senderInboxId: message.senderInboxId,
                        currentInboxId: params.client.inboxId,
                        conversationId: conversation.id,
                        activeConversationId: activeConversationId
                    ) {
                        try await localStateWriter.setUnread(true, for: conversation.id)
                    }

                    let perfElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - perfStart) * 1000)
                    Log.info("[PERF] message.process: \(perfElapsed)ms id=\(message.id)")
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
        let reason = error.reason ?? "none"
        Log.info("Received InviteJoinError (\(error.errorType.rawValue)) for inviteTag: \(error.inviteTag) from \(senderInboxId), reason: \(reason)")
        await inviteJoinErrorHandler?.handleInviteJoinError(error)
    }

    // MARK: - Read Receipts

    private func processReadReceipt(_ message: DecodedMessage, conversationId: String, currentInboxId: String) async -> Bool {
        guard message.isReadReceipt else {
            return false
        }

        let senderInboxId = message.senderInboxId

        guard senderInboxId != currentInboxId else {
            return true
        }

        let sentAtNs = message.sentAtNs
        Log.info("Received read receipt from \(senderInboxId) for conversation \(conversationId)")

        do {
            try await databaseWriter.write { db in
                let existing = try DBConversationReadReceipt
                    .filter(Column("conversationId") == conversationId && Column("inboxId") == senderInboxId)
                    .fetchOne(db)
                if let existing, existing.readAtNs >= sentAtNs {
                    // Newer (or equal) read receipt already stored; ignore this one so an
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
        } catch {
            Log.warning("Failed to store read receipt: \(error.localizedDescription)")
        }

        return true
    }

    // MARK: - Profile Messages

    /// Typing indicators are ephemeral UI signals — "X is typing" has no
    /// meaning outside the live window. When streams reconnect after the
    /// app was backgrounded or killed, libxmtp replays the backlog and
    /// historical typing indicators arrive alongside real messages. Without
    /// a freshness gate the UI would flash "X is typing" for someone who
    /// finished typing minutes ago. Drop anything older than the live
    /// window; the indicator's natural debounce on the sender side keeps
    /// this well above one round-trip of normal latency.
    private static let typingIndicatorLiveWindow: TimeInterval = 10

    private func processTypingIndicator(
        _ message: DecodedMessage,
        conversationId: String,
        params: SyncClientParams
    ) -> Bool {
        guard message.isTypingIndicator else {
            return false
        }

        guard message.senderInboxId != params.client.inboxId else {
            return true
        }

        let ageSeconds = Date().timeIntervalSince1970 - (TimeInterval(message.sentAtNs) / 1_000_000_000)
        guard ageSeconds <= Self.typingIndicatorLiveWindow else {
            Log.debug("Dropping stale typing indicator from \(message.senderInboxId) (age=\(Int(ageSeconds))s)")
            return true
        }

        guard let content = try? TypingIndicatorCodec().decode(content: message.encodedContent) else {
            Log.warning("Failed to decode TypingIndicator from message \(message.id)")
            return true
        }

        onTypingIndicator?(conversationId, message.senderInboxId, content.isTyping)
        return true
    }

    private func processThinking(
        _ message: DecodedMessage,
        conversationId: String,
        params: SyncClientParams
    ) async -> Bool {
        guard message.isThinking else {
            return false
        }

        guard message.senderInboxId != params.client.inboxId else {
            return true
        }

        guard let content = try? ThinkingCodec().decode(content: message.encodedContent) else {
            Log.warning("Failed to decode Thinking from message \(message.id)")
            return true
        }

        Log.info("[Thinking] received state=\(content.state.rawValue) target=\(content.targetMessageId) sender=\(message.senderInboxId) conversation=\(conversationId)")

        await thinkingSessionWriter.apply(
            event: content,
            momentId: message.id,
            conversationId: conversationId,
            senderInboxId: message.senderInboxId,
            sentAtNs: message.sentAtNs
        )
        return true
    }

    private func processProfileUpdate(_ message: DecodedMessage, conversationId: String) async {
        guard let update = try? ProfileUpdateCodec().decode(content: message.encodedContent) else {
            Log.warning("Failed to decode ProfileUpdate from message \(message.id)")
            return
        }
        let receivedAt = message.sentAt

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

                let priorMemberKind = profile.memberKind
                profile = profile.with(memberKind: update.memberKind.dbMemberKind)

                let profileMetadata = update.profileMetadata
                profile = profile.with(metadata: profileMetadata.isEmpty ? nil : profileMetadata)

                if profile.isAgent {
                    let verification = profile.hydrateProfile().verifyCachedAgentAttestation()
                    if verification.isVerified {
                        profile = profile.with(memberKind: DBMemberKind.from(agentVerification: verification))
                    }
                }

                if let priorMemberKind, priorMemberKind.agentVerification.isVerified,
                   !profile.agentVerification.isVerified {
                    profile = profile.with(memberKind: priorMemberKind)
                }

                try ContactsWriter.saveMemberProfileAndMirrorToContactInTransaction(db: db, profile: profile, receivedAt: receivedAt)
                try Self.markConversationHasVerifiedAgentIfNeeded(profile: profile, conversationId: conversationId, db: db)
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
        // Derived from `message.sentAt`, not wall-clock `Date()`.
        // Mirrors `processProfileUpdate`.
        let receivedAt = message.sentAt

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

                    let priorMemberKind = profile.memberKind
                    profile = profile.with(memberKind: memberProfile.memberKind.dbMemberKind)

                    let snapshotMetadata = memberProfile.profileMetadata
                    profile = profile.with(metadata: snapshotMetadata.isEmpty ? nil : snapshotMetadata)

                    if profile.isAgent {
                        let verification = profile.hydrateProfile().verifyCachedAgentAttestation()
                        if verification.isVerified {
                            profile = profile.with(memberKind: DBMemberKind.from(agentVerification: verification))
                        }
                    }

                    if let priorMemberKind, priorMemberKind.agentVerification.isVerified,
                       !profile.agentVerification.isVerified {
                        profile = profile.with(memberKind: priorMemberKind)
                    }

                    try ContactsWriter.saveMemberProfileAndMirrorToContactInTransaction(db: db, profile: profile, receivedAt: receivedAt)
                    try Self.markConversationHasVerifiedAgentIfNeeded(profile: profile, conversationId: conversationId, db: db)
                }
            }
            Log.debug("Processed ProfileSnapshot with \(snapshot.profiles.count) profiles in \(conversationId)")
        } catch {
            Log.error("Failed to process ProfileSnapshot: \(error.localizedDescription)")
        }
    }

    private static func markConversationHasVerifiedAgentIfNeeded(
        profile: DBMemberProfile,
        conversationId: String,
        db: Database
    ) throws {
        guard profile.agentVerification.isConvosAgent,
              let conversation = try DBConversation.fetchOne(db, id: conversationId),
              !conversation.hasHadVerifiedAgent else { return }
        try conversation.with(hasHadVerifiedAgent: true).save(db)
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
            // The contact's display name (the user's global profile snapshot
            // for this inbox) wins over the per-conversation profile name,
            // mirroring `Profile.formattedNamesString(memberNameOverride:)`.
            let name: String? = try await databaseReader.read { db in
                if let contactName = try ContactsRepository.contactNameInTransaction(db: db, inboxId: senderInboxId) {
                    return contactName
                }
                return try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: senderInboxId)?.name
            }
            if let name, !name.isEmpty {
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
    /// If consent is unknown but there's an outgoing join request, updates
    /// consent to allowed.
    ///
    /// Used by the message-stream path (`processMessage` → group case) to
    /// gate whether messages from a particular conversation should be
    /// processed. This intentionally does not consult the contact list or
    /// block list — blocking only affects new inbound conversation
    /// invitations, not in-group messages from an already-accepted sender.
    /// New-conversation arrival uses `decideInboundConversation`.
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

    /// Returns the inbound-conversation decision (deliver / reject) for a
    /// NEW inbound conversation. `processConversation` uses this to decide
    /// persistence. The message-stream path uses `shouldProcessConversation`
    /// so blocking does not silence in-group messages.
    ///
    /// Consent is the source of truth for feed visibility: a conversation
    /// reads as `.allowed` only once the local user has consented to it.
    /// As a side effect, this bumps XMTP consent `.unknown -> .allowed`
    /// when the local user has either requested to join (invite handshake)
    /// or already has the creator as a non-blocked contact. Unsolicited
    /// strangers stay `.unknown` (delivered but hidden from the feed) until
    /// the creator becomes a contact, at which point `SyncingManager`'s
    /// consent promoter flips them.
    private func decideInboundConversation(
        _ conversation: XMTPiOS.Group,
        params: SyncClientParams
    ) async throws -> InboundConversationDecision {
        let consent = try conversation.consentState().asConsent
        let creatorInboxId = try await conversation.creatorInboxId()
        let clientInboxId = params.client.inboxId

        // Only do the (potentially expensive) outgoing-join-request lookup
        // when the conversation is still unknown and not self-created.
        let hasOutgoingJoinRequest: Bool
        if consent == .unknown && creatorInboxId != clientInboxId {
            hasOutgoingJoinRequest = try await joinRequestsManager.hasOutgoingJoinRequest(
                for: conversation,
                client: params.client
            )
        } else {
            hasOutgoingJoinRequest = false
        }

        let decision = inboundFilter.decide(
            consentState: consent,
            creatorInboxId: creatorInboxId,
            clientInboxId: clientInboxId,
            hasOutgoingJoinRequest: hasOutgoingJoinRequest
        )

        // Bump XMTP consent to `.allowed` only when the local user has
        // consented to this conversation - either by requesting to join,
        // or because the creator is already a non-blocked contact. Strangers
        // are delivered but left `.unknown` so they stay out of the feed.
        if decision == .deliver, consent == .unknown, creatorInboxId != clientInboxId {
            let creatorIsContact = try await isNonBlockedContact(creatorInboxId)
            if hasOutgoingJoinRequest || creatorIsContact {
                try await conversation.updateConsentState(state: .allowed)
            }
        }

        return decision
    }

    /// True when `inboxId` is a stored contact that is not blocked. Mirrors
    /// the join used by the feed query and the consent promoter.
    private func isNonBlockedContact(_ inboxId: String) async throws -> Bool {
        try await databaseReader.read { db in
            try DBContact
                .filter(DBContact.Columns.inboxId == inboxId)
                .filter(DBContact.Columns.blockedAt == nil)
                .fetchCount(db) > 0
        }
    }

    // MARK: - Push Notifications

    func reconcilePushSubscriptions(params: SyncClientParams, context: String) async {
        await pushTopicSubscriptionManager.reconcilePushTopics(params: params, context: context)
    }

    func clearPushSubscriptionCache() async { await pushTopicSubscriptionManager.clearCache() }

    private func handleJoinRequestOutcome(
        _ outcome: InviteJoinRequestOutcome,
        params: SyncClientParams,
        context: String
    ) async {
        guard let dmConversationId = outcome.dmConversationId else { return }

        if outcome.shouldKeepDMSubscribed {
            await pushTopicSubscriptionManager.subscribeToInviteDMTopic(
                conversationId: dmConversationId,
                params: params,
                context: context
            )
        } else if case .malicious = outcome {
            await pushTopicSubscriptionManager.unsubscribeFromInviteDMTopic(
                conversationId: dmConversationId,
                params: params,
                context: context
            )
        }
    }
}

// MARK: - Builder Bundle Manifest

extension StreamProcessor {
    /// Persist the hidden bundle ids a `BuilderBundleManifest` carries so the
    /// messages list filters the agent brief out (see
    /// `BuilderBundleHiddenMessagesRepository`). Returns `true` when the message
    /// was a manifest (handled), so the caller stops further routing.
    func processBuilderBundleManifest(_ message: DecodedMessage, conversationId: String) async -> Bool {
        guard message.isBuilderBundleManifest else {
            return false
        }
        guard let manifest = try? BuilderBundleManifestCodec().decode(content: message.encodedContent),
              !manifest.messageIds.isEmpty else {
            return true
        }
        do {
            try await databaseWriter.write { db in
                for messageId in manifest.messageIds {
                    try DBBuilderBundleHiddenMessage(conversationId: conversationId, messageId: messageId)
                        .save(db, onConflict: .ignore)
                }
            }
        } catch {
            Log.warning("Failed to store builder bundle manifest: \(error.localizedDescription)")
        }
        return true
    }

    /// Routes a profile message (update or snapshot) to its handler. Returns
    /// `true` when handled, so the caller stops further routing -- profiles are
    /// applied by the profile handlers, never stored as chat rows.
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
}

// MARK: - Device Revocation

extension StreamProcessor {
    /// Pre-conversation-lookup fast path: `DeviceRemovedContent` doesn't need
    /// a conversation context — it's a system signal from the user's other
    /// installation saying "you've been revoked". Check it before the
    /// (potentially failing) findConversation call so a missing-conversation
    /// race doesn't suppress the banner trigger.
    ///
    /// Sender check: the signal is only meaningful when it comes from one
    /// of *our own* installations (the paired peer that performed the
    /// revoke). Without this, any participant in any shared conversation
    /// could forge a `DeviceRemovedContent` with our installationId and
    /// falsely trip the stale-device banner.
    ///
    /// Returns true when the message was handled and the caller should
    /// stop further processing.
    func handleDeviceRemovedFastPath(message: DecodedMessage, params: SyncClientParams) -> Bool {
        guard let typeId = try? message.encodedContent.type.typeID,
              typeId == ContentTypeDeviceRemoved.typeID,
              let removal = try? message.content() as DeviceRemovedContent,
              removal.revokedInstallationId == params.client.installationId,
              message.senderInboxId == params.client.inboxId else {
            return false
        }
        Log.info("StreamProcessor: received DeviceRemoved for our own installation \(params.client.installationId) — posting revocation notification")
        NotificationCenter.default.post(
            name: .installationWasRevokedByPeer,
            object: nil,
            userInfo: ["revokedInstallationId": removal.revokedInstallationId]
        )
        return true
    }
}
