import ConvosInvites
import ConvosMessagingProtocols
import Foundation
import GRDB
import UserNotifications
// FIXME: see docs/outstanding-messaging-abstraction-work.md#stream-wire-layer
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

    /// Abstraction-typed overload that accepts `MessagingGroup` and
    /// internally downcasts to `XMTPiOSMessagingGroup`. DTU-backed
    /// groups currently warn-and-skip — stream processing is
    /// XMTPiOS-only at the wire level today.
    func processConversation(
        group: any MessagingGroup,
        params: SyncClientParams,
        clientConversationId: String?
    ) async throws

    func processMessage(
        _ message: DecodedMessage,
        params: SyncClientParams,
        activeConversationId: String?
    ) async

    /// Gap 2 abstraction-typed sibling. SyncingManager Phase 3 routes
    /// `streamAllMessages` through `MessagingClient.conversations` and
    /// hands every yielded `MessagingMessage` to this overload.
    func processMessage(
        message: MessagingMessage,
        params: SyncClientParams,
        activeConversationId: String?
    ) async

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

    func processConversation(
        group: any MessagingGroup,
        params: SyncClientParams
    ) async throws {
        try await processConversation(group: group, params: params, clientConversationId: nil)
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
    private var onTypingIndicator: ((String, String, Bool) -> Void)?

    // MARK: - Initialization

    init(
        identityStore: any KeychainIdentityStoreProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil,
        notificationCenter: any UserNotificationCenterProtocol
    ) {
        self.identityStore = identityStore
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.deviceRegistrationManager = deviceRegistrationManager
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

    /// Stream-processor entry point that flows on the abstraction
    /// surface for both XMTPiOS and DTU backings. SyncingManager routes
    /// its conversation stream through
    /// `MessagingClient.conversations.streamAll(...)`, so DTU-backed
    /// groups arrive here through the same code path as XMTPiOS-backed
    /// ones. The XMTPiOS-specific bits
    /// (`ProfileSnapshotBuilder.sendSnapshot` + the invite-flow
    /// back-channel) downcast at the call site so they stay
    /// XMTPiOS-only.
    func processConversation(
        group: any MessagingGroup,
        params: SyncClientParams,
        clientConversationId: String? = nil
    ) async throws {
        guard try await shouldProcessConversation(group: group, params: params) else {
            return
        }

        let creatorInboxId = try await group.creatorInboxId()
        if creatorInboxId == params.client.inboxId {
            // We created the conversation: ensure the invite tag and
            // image-encryption key are in place, then ensure the
            // add-member permission is `.allow`. DTU's engine doesn't
            // have these add-on metadata fields; the abstraction-side
            // helpers handle the cross-backend behaviour
            // (`ensureInviteTag` / `ensureImageEncryptionKey` are
            // implemented in `MessagingGroup+CustomMetadata.swift`).
            try await group.ensureInviteTag()
            do {
                try await group.ensureImageEncryptionKey()
            } catch {
                Log.warning("Failed to generate image encryption key: \(error). Will retry on first image upload.")
            }
            // Permission policy isn't surfaced uniformly across DTU
            // (DTU returns `.unknown` until the engine models it).
            // Update only when both states are known.
            do {
                let permissions = try await group.permissionPolicySet()
                if permissions.addMemberPolicy != .allow,
                   permissions.addMemberPolicy != .deny,
                   permissions.addMemberPolicy != .unknown {
                    try await group.updateAddMemberPermission(.allow)
                }
            } catch {
                // DTU engines without permission-policy support throw
                // `DTUMessagingNotSupportedError`; that's fine, we
                // don't need to gate persistence on it.
                Log.debug("permissionPolicySet/updateAddMemberPermission skipped: \(error)")
            }
        }

        let perfStart = CFAbsoluteTimeGetCurrent()
        Log.info("Syncing conversation: \(group.id)")
        try await conversationWriter.storeWithLatestMessages(
            conversation: group,
            inboxId: params.client.inboxId,
            clientConversationId: clientConversationId
        )
        let perfElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - perfStart) * 1000)
        Log.info("[PERF] conversation.sync: \(perfElapsed)ms id=\(group.id)")

        if creatorInboxId == params.client.inboxId {
            // ProfileSnapshot send is XMTPiOS-only (XIP-payload +
            // ConvosProfiles wire layer). DTU-backed groups skip this
            // until ConvosProfiles migrates onto the abstraction.
            await sendInitialProfileSnapshot(group: group)
        }

        // Subscribe to push notifications
        await subscribeToConversationTopics(
            conversationId: group.id,
            params: params,
            context: "on stream"
        )
    }

    func processConversation(
        _ conversation: XMTPiOS.Group,
        params: SyncClientParams,
        clientConversationId: String? = nil
    ) async throws {
        guard try await shouldProcessConversation(conversation, params: params) else { return }

        let creatorInboxId = try await conversation.creatorInboxId()
        if creatorInboxId == params.client.inboxId {
            // Custom-metadata calls (`ensureInviteTag`,
            // `ensureImageEncryptionKey`) live on `MessagingGroup` via
            // `MessagingGroup+CustomMetadata.swift`; wrap the
            // `XMTPiOS.Group` once for this block.
            let messagingGroup: any MessagingGroup = XMTPiOSMessagingGroup(xmtpGroup: conversation)

            // we created the conversation, update permissions, set inviteTag, and generate encryption key
            try await messagingGroup.ensureInviteTag()
            do {
                try await messagingGroup.ensureImageEncryptionKey()
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
        // `conversationWriter` takes `any MessagingGroup`; wrap the
        // raw `XMTPiOS.Group` at the call site.
        try await conversationWriter.storeWithLatestMessages(
            conversation: XMTPiOSMessagingGroup(xmtpGroup: conversation),
            inboxId: params.client.inboxId,
            clientConversationId: clientConversationId
        )
        let perfElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - perfStart) * 1000)
        Log.info("[PERF] conversation.sync: \(perfElapsed)ms id=\(conversation.id)")

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

    /// Gap 2 abstraction-typed sibling. Handles a `MessagingMessage`
    /// that arrived via `MessagingClient.conversations.streamAllMessages(...)`
    /// (XMTPiOS or DTU) without a round-trip through `DecodedMessage`.
    /// Skips DM/invite back-channel work (XMTPiOS-only today) and
    /// otherwise mirrors the XMTPiOS-typed `processMessage`'s group flow
    /// against the abstraction-side helpers
    /// (`MessagingMessage.isProfileMessage`, `isTypingIndicator`,
    /// `isReadReceipt`). XMTPiOS-backed messages use the existing
    /// `DecodedMessage`-typed path so the join-flow / DM back-channel
    /// keep their handle.
    func processMessage(
        message messagingMessage: MessagingMessage,
        params: SyncClientParams,
        activeConversationId: String?
    ) async {
        let perfStart = CFAbsoluteTimeGetCurrent()
        do {
            guard let messagingConversation = try await params.client
                .conversations.find(conversationId: messagingMessage.conversationId)
            else {
                Log.error("Conversation not found for message")
                return
            }

            switch messagingConversation {
            case .dm:
                // Invite-flow DM back-channel is XMTPiOS-only; on DTU
                // we skip. The XMTPiOS lane uses the DecodedMessage-typed
                // overload below.
                Log.debug("processMessage(message:): skipping DM message on abstraction lane")
                return
            case .group(let messagingGroup):
                guard try await shouldProcessConversation(
                    group: messagingGroup,
                    params: params
                ) else {
                    Log.warning("Received invalid group message, skipping...")
                    return
                }

                let dbConversation = try await conversationWriter.store(
                    conversation: messagingGroup,
                    inboxId: params.client.inboxId
                )

                // Handle ExplodeSettings — skip storing message if this is
                // an explode message
                let explodeSettings = messageWriter.decodeExplodeSettings(from: messagingMessage)
                if let explodeSettings {
                    await processExplodeSettings(
                        explodeSettings,
                        senderInboxId: messagingMessage.senderInboxId,
                        group: messagingGroup,
                        params: params
                    )
                }
                guard explodeSettings == nil else { return }

                if messagingMessage.isProfileMessage {
                    // ProfileUpdate / ProfileSnapshot processing is
                    // XMTPiOS-typed (uses ConvosProfiles codecs). DTU
                    // skips and lets the message land as a regular row;
                    // the codec doesn't decode there yet, so we drop
                    // it instead of misclassifying it as application.
                    Log.debug("processMessage(message:): skipping profile message on abstraction lane")
                    return
                }

                if messagingMessage.isTypingIndicator {
                    // No-op on the DTU lane; the XMTPiOS lane handles
                    // typing indicators via the DecodedMessage path.
                    return
                }

                if messagingMessage.isReadReceipt {
                    // No-op for the abstraction lane today; receipt
                    // processing relies on the XMTPiOS senderInboxId
                    // assertion which `MessagingMessage` already exposes
                    // — wire it up when DTU integration tests start
                    // exercising read receipts.
                    return
                }

                // System / membership-change messages on the DTU lane
                // (e.g. xmtp.org/group_updated). The XMTPiOS adapter's
                // `resolvedPayload()` decodes these via XIP into an
                // `XMTPiOS.GroupUpdated`; DTU's encoded content for
                // these system messages doesn't carry an XIP-decoded
                // `GroupUpdated`, so let the conversation row be the
                // record-of-truth and skip writing a `DBMessage` row.
                // The conversation member-list reconciliation is
                // handled by the conversation-stream / list paths.
                if messagingMessage.encodedContent.type.authorityID == "xmtp.org",
                   messagingMessage.encodedContent.type.typeID == "group_updated" {
                    Log.debug("processMessage(message:): skipping group_updated system message \(messagingMessage.id)")
                    return
                }

                let result = try await messageWriter.store(
                    message: messagingMessage,
                    for: dbConversation
                )

                // Mark unread if needed
                if result.contentType.marksConversationAsUnread,
                   messagingMessage.conversationId != activeConversationId,
                   messagingMessage.senderInboxId != params.client.inboxId {
                    try await localStateWriter.setUnread(
                        true,
                        for: messagingMessage.conversationId
                    )
                }

                let perfElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - perfStart) * 1000)
                Log.info("[PERF] message.process: \(perfElapsed)ms id=\(messagingMessage.id)")
            }
        } catch {
            Log.warning("Stopped processing message from error: \(error.localizedDescription)")
        }
    }

    /// Gap 2: abstraction-typed sibling for explode-settings handling.
    /// `processExplodeSettings` only needs the conversation id + name;
    /// downcast to XMTPiOS for the name lookup when available, fall
    /// back to `group.name()` (or the abstraction's blank string for
    /// DTU which doesn't model name) otherwise.
    private func processExplodeSettings(
        _ settings: ExplodeSettings,
        senderInboxId: String,
        group: any MessagingGroup,
        params: SyncClientParams
    ) async {
        let result = await messageWriter.processExplodeSettings(
            settings,
            conversationId: group.id,
            senderInboxId: senderInboxId,
            currentInboxId: params.client.inboxId
        )

        let conversationName: String = await {
            if let name = try? await group.name(), !name.isEmpty {
                return name
            }
            return "Untitled"
        }()

        switch result {
        case .applied:
            await postExplosionNotification(
                conversationName: conversationName,
                conversationId: group.id
            )
        case .scheduled(let expiresAt):
            let senderName = await getSenderDisplayName(
                senderInboxId: senderInboxId,
                conversationId: group.id
            )
            await postScheduledExplosionNotification(
                senderName: senderName,
                conversationName: conversationName,
                conversationId: group.id,
                expiresAt: expiresAt
            )
        case .fromSelf, .alreadyExpired, .unauthorized:
            break
        }
    }

    func processMessage(
        _ message: DecodedMessage,
        params: SyncClientParams,
        activeConversationId: String?
    ) async {
        let perfStart = CFAbsoluteTimeGetCurrent()
        do {
            // The conversation lookup goes through the abstraction;
            // `shouldProcessConversation` and `processExplodeSettings`
            // still need the raw `XMTPiOS.Group`, so we reach it via
            // the `XMTPiOSMessagingGroup` bridge below.
            guard let messagingConversation = try await params.client
                .conversations.find(conversationId: message.conversationId)
            else {
                Log.error("Conversation not found for message")
                return
            }

            switch messagingConversation {
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
            case .group(let messagingGroup):
                do {
                    guard let xmtpAdapter = messagingGroup as? XMTPiOSMessagingGroup else {
                        Log.warning("StreamProcessor.processMessage: non-XMTPiOS group adapter; skipping")
                        return
                    }
                    let conversation = xmtpAdapter.underlyingXMTPiOSGroup
                    guard try await shouldProcessConversation(conversation, params: params) else {
                        Log.warning("Received invalid group message, skipping...")
                        return
                    }

                    let dbConversation = try await conversationWriter.store(
                        conversation: messagingGroup,
                        inboxId: params.client.inboxId
                    )

                    // Writers operate on `MessagingMessage`; wrap the
                    // stream-provided `DecodedMessage` once for the
                    // writer-bound calls.
                    let messagingMessage = try MessagingMessage(message)

                    // Handle ExplodeSettings - skip storing message if this is an explode message
                    let explodeSettings = messageWriter.decodeExplodeSettings(from: messagingMessage)
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

                    if processTypingIndicator(message, conversationId: conversation.id, params: params) {
                        return
                    }

                    if await processReadReceipt(message, conversationId: conversation.id, currentInboxId: params.client.inboxId) {
                        return
                    }

                    let result = try await messageWriter.store(message: messagingMessage, for: dbConversation)

                    // Mark unread if needed
                    if result.contentType.marksConversationAsUnread,
                       conversation.id != activeConversationId,
                       message.senderInboxId != params.client.inboxId {
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
        Log.info("Received InviteJoinError (\(error.errorType.rawValue)) for inviteTag: \(error.inviteTag) from \(senderInboxId)")
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

        guard let content = try? TypingIndicatorCodec().decode(content: message.encodedContent) else {
            Log.warning("Failed to decode TypingIndicator from message \(message.id)")
            return true
        }

        onTypingIndicator?(conversationId, message.senderInboxId, content.isTyping)
        return true
    }

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

                try profile.save(db)
                try Self.markConversationHasVerifiedAssistantIfNeeded(profile: profile, conversationId: conversationId, db: db)
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

                    try profile.save(db)
                    try Self.markConversationHasVerifiedAssistantIfNeeded(profile: profile, conversationId: conversationId, db: db)
                }
            }
            Log.debug("Processed ProfileSnapshot with \(snapshot.profiles.count) profiles in \(conversationId)")
        } catch {
            Log.error("Failed to process ProfileSnapshot: \(error.localizedDescription)")
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

    /// Abstraction-typed sibling that downcasts on XMTPiOS and
    /// silently no-ops on DTU. The XIP-payload codec layer in
    /// `ConvosProfiles` is XMTPiOS-only; the no-op branch becomes a
    /// real send via `ProfileSnapshotBridge` once that codec migrates
    /// onto the abstraction.
    private func sendInitialProfileSnapshot(group: any MessagingGroup) async {
        guard let xmtpAdapter = group as? XMTPiOSMessagingGroup else {
            // DTU: ProfileSnapshot is a Convos XIP-payload that the
            // current ConvosProfiles writer only knows how to encode +
            // send through the XMTPiOS codec pipeline. Skipping is
            // safe — receivers reconstruct profiles from per-message
            // ProfileUpdate payloads.
            Log.debug("sendInitialProfileSnapshot: skipping snapshot for non-XMTPiOS group \(group.id)")
            return
        }
        await sendInitialProfileSnapshot(group: xmtpAdapter.underlyingXMTPiOSGroup)
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

    /// Gap 2 abstraction-typed sibling. Mirrors the XMTPiOS-typed
    /// version's three-step decision tree (allowed-already → creator-is-self
    /// → outgoing-invite). The hasOutgoingJoinRequest check still routes
    /// through the InviteJoinRequestsManager which today demands an
    /// `XMTPiOS.Group` (DM back-channel is XMTPiOS-only); on DTU we
    /// short-circuit to "consent is allowed" because the engine has no
    /// invite-flow back-channel today, so the only meaningful gate is
    /// whether the local consent state is allowed/unknown.
    private func shouldProcessConversation(
        group: any MessagingGroup,
        params: SyncClientParams
    ) async throws -> Bool {
        var consentState = try await group.consentState()
        guard consentState != .allowed else {
            return true
        }

        guard try await group.creatorInboxId() != params.client.inboxId else {
            return true
        }

        if consentState == .unknown {
            // Invite-flow back-channel is XMTPiOS-only today (the
            // coordinator's DM lookups + signed-invite payloads sit on
            // top of `ConvosInvites` which still consumes XMTPiOS-typed
            // DM handles). DTU-backed groups don't generate join
            // requests in any of the integration tests; treat them as
            // allowed when consent is unknown so DTU lanes don't get
            // stuck on a coordinator code path that has no DTU
            // implementation.
            if let xmtpAdapter = group as? XMTPiOSMessagingGroup {
                let hasOutgoingJoinRequest = try await joinRequestsManager.hasOutgoingJoinRequest(
                    for: xmtpAdapter.underlyingXMTPiOSGroup,
                    client: params.client
                )
                if hasOutgoingJoinRequest {
                    try await group.updateConsentState(.allowed)
                    consentState = try await group.consentState()
                }
            } else {
                // DTU: no invite back-channel; treat as ready to process.
                return true
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

        guard let identity = try? await identityStore.load(), identity.inboxId == params.client.inboxId else {
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
