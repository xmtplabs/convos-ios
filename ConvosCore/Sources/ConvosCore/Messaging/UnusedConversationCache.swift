import ConvosMetrics
import Foundation
import GRDB
@preconcurrency import XMTPiOS

// MARK: - UnusedConversationCacheProtocol

/// Pre-creates an XMTP group on the authorized messaging service so the first
/// "new conversation" a user taps into is already published. The pre-created
/// group lives as a `DBConversation` row with `isUnused = true` (hidden from
/// the chats list). Callers claim one via `consumeUnusedConversationId`,
/// then either `commitClaimedConversation` to make it visible, or
/// `releaseClaimedConversationId` to drop the claim if the row is being
/// discarded. The DB row stays `isUnused = true` for the entire claim
/// window so it never surfaces in the conversations list before the user
/// has committed.
public protocol UnusedConversationCacheProtocol: Actor {
    /// Schedules pre-creation of an unused conversation on `service`.
    /// Idempotent: no-op if a preparation task is already in flight or an
    /// unclaimed unused row already exists in the DB.
    func prepareUnusedConversation(
        service: any MessagingServiceProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async

    /// Claims the next available pre-warmed conversation. Returns its id
    /// or `nil` if the pool is empty. Does NOT change the row — the row
    /// stays `isUnused = true` so the chats list keeps hiding it. The id
    /// is tracked in memory so subsequent claims skip it and so the
    /// prewarmer treats the pool as drained.
    func consumeUnusedConversationId(
        databaseWriter: any DatabaseWriter
    ) async -> String?

    /// Promotes a previously-claimed row into a real visible conversation:
    /// flips `isUnused` to `false`, refreshes `createdAt` to now (so the
    /// row sorts at the top of the chats list), and drops the in-memory
    /// claim. Idempotent for ids that aren't currently claimed.
    func commitClaimedConversation(
        id conversationId: String,
        databaseWriter: any DatabaseWriter
    ) async

    /// Drops the in-memory claim without writing to the DB. Pairs with
    /// `SessionManager.discardClaimedConversation`, which deletes the row
    /// itself — the claim must be cleared so a fresh prewarm can run.
    func releaseClaimedConversationId(_ conversationId: String) async

    /// Registers an externally-created conversation id as claimed so
    /// `consumeUnusedConversationId` can't hand the same row to another
    /// caller while it's actively in use (e.g. the agent builder's
    /// auto-created hidden conversation). In-memory only: an app restart
    /// clears the claim, which makes an abandoned row consumable again.
    func registerClaimedConversation(id conversationId: String) async

    /// Cancels any in-flight preparation task and awaits its unwind. Call
    /// during inbox teardown so a late-resolving prewarm can't land a stale
    /// row in a fresh DB after teardown returns.
    func cancel() async
}

// MARK: - UnusedConversationCache

public actor UnusedConversationCache: UnusedConversationCacheProtocol {
    private let identityStore: any KeychainIdentityStoreProtocol
    private var backgroundCreationTask: Task<Void, Never>?
    private var lastPreparationFailure: Date?
    /// Conversation ids handed out by `consumeUnusedConversationId` that
    /// haven't yet been committed or released. Excluded from subsequent
    /// `consume` and `hasUnusedConversationInDatabase` queries so the
    /// same row isn't handed to two callers and the prewarmer correctly
    /// treats them as drained (prepares a replacement).
    private var claimedConversationIds: Set<String> = []
    private static let preparationCooldown: TimeInterval = 30

    public init(identityStore: any KeychainIdentityStoreProtocol) {
        self.identityStore = identityStore
    }

    // MARK: - Public

    public func prepareUnusedConversation(
        service: any MessagingServiceProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {
        if backgroundCreationTask != nil {
            Log.debug("Unused conversation preparation already in flight, skipping...")
            return
        }
        if let lastFailure = lastPreparationFailure,
           Date().timeIntervalSince(lastFailure) < Self.preparationCooldown {
            let remaining = Int(Self.preparationCooldown - Date().timeIntervalSince(lastFailure))
            Log.debug("Skipping unused conversation preparation — cooldown active (\(remaining)s remaining)")
            return
        }

        backgroundCreationTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            if await self.hasUnusedConversationInDatabase(databaseReader: databaseReader) {
                Log.debug("Unused conversation already cached, skipping...")
                await self.clearBackgroundCreationTask()
                return
            }
            await self.runPreparation(
                service: service,
                databaseWriter: databaseWriter,
                environment: environment
            )
        }
    }

    private func clearBackgroundCreationTask() {
        backgroundCreationTask = nil
    }

    public func consumeUnusedConversationId(
        databaseWriter: any DatabaseWriter
    ) async -> String? {
        let claimedSnapshot = claimedConversationIds
        do {
            let claimedId: String? = try await databaseWriter.read { db -> String? in
                var request = Self.consumableUnusedConversationRequest()
                if !claimedSnapshot.isEmpty {
                    request = request.filter(!claimedSnapshot.contains(DBConversation.Columns.id))
                }
                return try request.fetchOne(db)?.id
            }
            if let claimedId {
                claimedConversationIds.insert(claimedId)
            }
            return claimedId
        } catch {
            Log.error("Failed to consume unused conversation: \(error)")
            return nil
        }
    }

    /// Rows eligible for handout: hidden, cache-shaped
    /// (`clientConversationId == id`), and fully prepared (real invite
    /// tag). The agent builder's deferred-visibility stubs carry their
    /// draft client id and are owned by that flow until committed or
    /// discarded - handing one to a second caller would put two flows on
    /// one conversation. Rows still carrying a provisional or empty tag
    /// never finished preparation (publish or tag write failed), so they
    /// stay out of the pool rather than risk surfacing a placeholder tag
    /// in an invite.
    private static func consumableUnusedConversationRequest() -> QueryInterfaceRequest<DBConversation> {
        DBConversation
            .filter(DBConversation.Columns.isUnused == true)
            .filter(DBConversation.Columns.clientConversationId == DBConversation.Columns.id)
            .filter(length(DBConversation.Columns.inviteTag) > 0)
            .filter(!DBConversation.Columns.inviteTag.like("\(provisionalInviteTagPrefix)%"))
    }

    public func commitClaimedConversation(
        id conversationId: String,
        databaseWriter: any DatabaseWriter
    ) async {
        let now = Date()
        do {
            try await databaseWriter.write { db in
                try db.execute(
                    sql: "UPDATE conversation SET isUnused = ?, createdAt = ? WHERE id = ?",
                    arguments: [false, now, conversationId]
                )
            }
            // Only drop the claim once the row is actually committed.
            // If the write failed the row stays `isUnused = true` and
            // dropping the claim here would let `consumeUnusedConversationId`
            // hand the same id out to another caller while the original
            // caller may still be using it.
            claimedConversationIds.remove(conversationId)
        } catch {
            Log.error("Failed to commit claimed conversation \(conversationId): \(error)")
        }
    }

    public func releaseClaimedConversationId(_ conversationId: String) async {
        claimedConversationIds.remove(conversationId)
    }

    public func registerClaimedConversation(id conversationId: String) async {
        claimedConversationIds.insert(conversationId)
    }

    public func cancel() async {
        let task = backgroundCreationTask
        backgroundCreationTask = nil
        task?.cancel()
        await task?.value
    }

    // MARK: - Private

    private func hasUnusedConversationInDatabase(
        databaseReader: any DatabaseReader
    ) async -> Bool {
        let claimedSnapshot = claimedConversationIds
        do {
            return try await databaseReader.read { db in
                // Mirrors `consumeUnusedConversationId`'s eligibility so a
                // row consume would skip (builder stub, half-prepared row)
                // can't suppress preparing a fresh consumable one.
                var request = Self.consumableUnusedConversationRequest()
                if !claimedSnapshot.isEmpty {
                    request = request.filter(!claimedSnapshot.contains(DBConversation.Columns.id))
                }
                return try request.fetchCount(db) > 0
            }
        } catch {
            Log.error("Failed to query existing unused conversation: \(error)")
            return false
        }
    }

    private func runPreparation(
        service: any MessagingServiceProtocol,
        databaseWriter: any DatabaseWriter,
        environment: AppEnvironment
    ) async {
        defer { backgroundCreationTask = nil }

        // Explicit `Task.checkCancellation()` checkpoints at each boundary
        // so `cancel()` (called during `tearDownInbox`) propagates through
        // deterministically. Relying on the underlying XMTP/GRDB awaits to
        // honor cancellation is not reliable — libxmtp's FFI wrappers and
        // GRDB's serial writer both tend to run to completion. A cancelled
        // task must hit the catch block so the network group and any DB row
        // are rolled back in tandem.
        let inboxId: String
        let group: XMTPiOS.Group
        nonisolated(unsafe) let optimisticConversation: any ConversationSender
        do {
            try Task.checkCancellation()
            let inboxReady = try await service.sessionStateManager.waitForInboxReadyResult()
            try Task.checkCancellation()
            let client = inboxReady.client
            inboxId = client.inboxId
            optimisticConversation = try client.prepareConversation()
            guard let xmtpGroup = optimisticConversation as? XMTPiOS.Group else {
                Log.error("Pre-created conversation was not a group; abandoning")
                lastPreparationFailure = Date()
                return
            }
            group = xmtpGroup
        } catch is CancellationError {
            // Teardown asked us to stop; no cooldown because this isn't a
            // real failure, and nothing to roll back - preparation is local
            // until the row write and publish below.
            return
        } catch {
            Log.error("Failed to pre-create unused conversation: \(error)")
            lastPreparationFailure = Date()
            return
        }

        // Write the hidden row before `publish()` so the conversation
        // stream's echo of the new group finds an existing `isUnused = true`
        // row and preserves it. Before this ordering, the row was only
        // written after publish, so the echo raced it and inserted a fresh
        // visible row - the conversation briefly flashed in the chats list
        // until the late write flipped it back to hidden. The provisional
        // tag (unique per conversation)
        // avoids colliding on the column's UNIQUE constraint when several
        // hidden stubs exist at once; `ensureInviteTag` below replaces it
        // with the real tag. Self-claim for the whole preparation window so
        // `consumeUnusedConversationId` can't hand out a group that hasn't
        // finished publishing; the claim is dropped once the row is fully
        // prepared (or rolled back).
        claimedConversationIds.insert(group.id)
        var dbRowWritten = false
        var published = false
        do {
            _ = try await writeUnusedConversation(
                conversation: group,
                inviteTag: Self.provisionalInviteTag(for: group.id),
                inboxId: inboxId,
                databaseWriter: databaseWriter
            )
            dbRowWritten = true
            try Task.checkCancellation()
            try await optimisticConversation.publish()
            published = true
            try Task.checkCancellation()
            try await group.ensureInviteTag()
            try Task.checkCancellation()
            do {
                try await group.ensureImageEncryptionKey()
            } catch {
                Log.warning("Failed to generate image encryption key for unused conversation: \(error). Will retry on first image upload.")
            }
            try Task.checkCancellation()

            let dbConversation = try await writeUnusedConversation(
                conversation: group,
                inviteTag: try group.inviteTag,
                inboxId: inboxId,
                databaseWriter: databaseWriter
            )
            try Task.checkCancellation()

            let inviteWriter = InviteWriter(
                identityStore: identityStore,
                databaseWriter: databaseWriter,
                coreActions: NoOpCoreActions()
            )
            _ = try await inviteWriter.generate(for: dbConversation)

            lastPreparationFailure = nil
            claimedConversationIds.remove(group.id)
            Log.debug("Pre-created unused conversation: \(group.id)")
        } catch {
            let isCancellation = error is CancellationError
            if isCancellation {
                Log.debug("Unused conversation preparation cancelled; rolling back.")
            } else {
                Log.error("Failed to finish unused conversation setup: \(error). Rolling back to keep state consistent.")
                lastPreparationFailure = Date()
            }

            // A thrown `publish()` does not guarantee the group missed the
            // network - libxmtp can fail on its local Diesel write after the
            // payload landed, and the stream then echoes the group back. If
            // the row were deleted here, that echo would re-insert it as a
            // visible row (the exact flash this method exists to prevent).
            // So a publish-failure keeps the hidden row and its claim: if
            // the group landed it gets recycled as the next prewarm after
            // restart; if it didn't, the row stays hidden and harmless.
            // Cancellation still rolls back fully - teardown must leave a
            // clean DB.
            if !published && dbRowWritten && !isCancellation {
                Log.warning("Keeping hidden unused-conversation row \(group.id) after publish failure; it is recycled or stays hidden.")
                return
            }

            // Log leave-group failures at error level so telemetry can
            // detect orphaned MLS groups (live on the XMTP network with no
            // local record). Low-probability — we're the sole member and
            // the group hasn't been shared yet — but a persistent stream
            // of these would point to a libxmtp reconnect issue worth
            // investigating. Group id is included so the orphan can be
            // matched against XMTP-side state if needed.
            if published {
                do {
                    try await group.leaveGroup()
                } catch {
                    Log.error("Failed to leave unused-conversation group \(group.id) after post-publish rollback: \(error). Group may remain live on the XMTP network.")
                }
            }
            if dbRowWritten {
                let conversationId = group.id
                try? await databaseWriter.write { db in
                    try ConversationLocalState
                        .filter(ConversationLocalState.Columns.conversationId == conversationId)
                        .deleteAll(db)
                    try DBMemberProfile
                        .filter(DBMemberProfile.Columns.conversationId == conversationId)
                        .deleteAll(db)
                    try DBConversationMember
                        .filter(DBConversationMember.Columns.conversationId == conversationId)
                        .deleteAll(db)
                    try DBConversation.deleteOne(db, key: conversationId)
                }
            }
            claimedConversationIds.remove(group.id)
        }
    }

    /// Prefix marking an invite tag as a pre-publish placeholder. Mirrors
    /// the `DBConversation.draftPrefix` pattern: every producer and
    /// consumer of provisional tags derives from this one constant.
    static let provisionalInviteTagPrefix: String = "pending-"

    /// Unique placeholder for the pre-publish row write. The real tag only
    /// exists after `ensureInviteTag()`, but `conversation.inviteTag` has a
    /// UNIQUE constraint, so concurrent hidden stubs (prewarm + agent
    /// builder) can't both use an empty string.
    static func provisionalInviteTag(for conversationId: String) -> String {
        "\(provisionalInviteTagPrefix)\(conversationId)"
    }

    static func isProvisionalInviteTag(_ inviteTag: String) -> Bool {
        inviteTag.hasPrefix(provisionalInviteTagPrefix)
    }

    /// Writes the pre-created group to GRDB in one pass. Called twice per
    /// preparation: once before `publish()` with an empty invite tag (so the
    /// stream's echo of the new group preserves the hidden row instead of
    /// inserting a visible one), and once after `ensureInviteTag()` with the
    /// real tag. Treats a pre-existing row with the same id as a benign
    /// collision (carry its local state, flip `isUnused` back to true)
    /// rather than a surprise - callers of the cache may have touched the
    /// row in flight.
    private func writeUnusedConversation(
        conversation: XMTPiOS.Group,
        inviteTag: String,
        inboxId: String,
        databaseWriter: any DatabaseWriter
    ) async throws -> DBConversation {
        let conversationId = conversation.id
        let createdAt = conversation.createdAt

        return try await databaseWriter.write { db in
            try Self.writeUnusedConversationRow(
                db: db,
                conversationId: conversationId,
                clientConversationId: conversationId,
                inviteTag: inviteTag,
                inboxId: inboxId,
                createdAt: createdAt
            )
        }
    }

    /// Shared row-shape for a hidden (`isUnused = true`) conversation,
    /// usable inside any GRDB write. Also used by
    /// `ConversationStateMachine.handleCreate` when a flow creates its
    /// conversation with deferred visibility (`startsUnused`), so both
    /// hidden-creation paths stay byte-identical. `inboxId` is both the
    /// creator and sole member - these rows only exist for self-created
    /// groups. An existing row with the same id is flipped back to hidden;
    /// an empty or provisional `inviteTag` never clobbers a real tag
    /// already on the row.
    @discardableResult
    static func writeUnusedConversationRow(
        db: Database,
        conversationId: String,
        clientConversationId: String,
        inviteTag: String,
        inboxId: String,
        createdAt: Date
    ) throws -> DBConversation {
        try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)

        let dbConversation: DBConversation
        if let existing = try DBConversation.fetchOne(db, key: conversationId) {
            let incomingIsPlaceholder: Bool = inviteTag.isEmpty || isProvisionalInviteTag(inviteTag)
            let preservedTag: String = incomingIsPlaceholder && !existing.inviteTag.isEmpty ? existing.inviteTag : inviteTag
            dbConversation = existing
                .with(isUnused: true)
                .with(inviteTag: preservedTag)
            try dbConversation.update(db)
        } else {
            dbConversation = DBConversation(
                id: conversationId,
                clientConversationId: clientConversationId,
                inviteTag: inviteTag,
                creatorId: inboxId,
                kind: .group,
                consent: .allowed,
                createdAt: createdAt,
                name: nil,
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeInfoInPublicPreview: true,
                expiresAt: nil,
                debugInfo: .empty,
                isLocked: false,
                imageSalt: nil,
                imageNonce: nil,
                imageEncryptionKey: nil,
                conversationEmoji: nil,
                imageLastRenewed: nil,
                isUnused: true,
                hasHadVerifiedAgent: false
            )
            try dbConversation.save(db)
        }

        try DBConversationMember(
            conversationId: conversationId,
            inboxId: inboxId,
            role: .superAdmin,
            consent: .allowed,
            createdAt: Date(),
            invitedByInboxId: nil
        ).save(db, onConflict: .ignore)

        try DBMemberProfile(
            conversationId: conversationId,
            inboxId: inboxId,
            name: nil,
            avatar: nil
        ).save(db, onConflict: .ignore)

        try ConversationLocalState(
            conversationId: conversationId,
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: Date.distantPast,
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false,
            hasHadOtherMembers: false,
            hasSharedInvite: false
        ).save(db, onConflict: .ignore)

        return dbConversation
    }
}
