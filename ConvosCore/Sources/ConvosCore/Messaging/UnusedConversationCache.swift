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
                var request = DBConversation
                    .filter(DBConversation.Columns.isUnused == true)
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
                var request = DBConversation
                    .filter(DBConversation.Columns.isUnused == true)
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
        // task post-publish must hit the catch block so the network group
        // and any DB row are rolled back in tandem.
        let inboxId: String
        let group: XMTPiOS.Group
        do {
            try Task.checkCancellation()
            let inboxReady = try await service.sessionStateManager.waitForInboxReadyResult()
            try Task.checkCancellation()
            let client = inboxReady.client
            inboxId = client.inboxId
            nonisolated(unsafe) let optimisticConversation = try client.prepareConversation()
            try await optimisticConversation.publish()
            try Task.checkCancellation()
            guard let xmtpGroup = optimisticConversation as? XMTPiOS.Group else {
                Log.error("Pre-created conversation was not a group; abandoning")
                lastPreparationFailure = Date()
                return
            }
            group = xmtpGroup
        } catch is CancellationError {
            // Teardown asked us to stop; no cooldown because this isn't a
            // real failure, and nothing to roll back since publish was the
            // only network side effect and it either didn't run or ran to
            // completion (in which case the post-publish branch below owns
            // rollback).
            return
        } catch {
            Log.error("Failed to pre-create unused conversation: \(error)")
            lastPreparationFailure = Date()
            return
        }

        // Post-publish work: the group is live on the XMTP network. Any
        // failure past this point must leave both sides in sync —
        // `leaveGroup()` to get off the network, and the DB row deleted
        // (if we already wrote it) so `consumeUnusedConversationId` can't
        // hand out an id pointing to a group we already left.
        var dbRowWritten = false
        do {
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
                inboxId: inboxId,
                databaseWriter: databaseWriter
            )
            dbRowWritten = true
            try Task.checkCancellation()

            let inviteWriter = InviteWriter(
                identityStore: identityStore,
                databaseWriter: databaseWriter,
                coreActions: NoOpCoreActions()
            )
            _ = try await inviteWriter.generate(for: dbConversation)

            lastPreparationFailure = nil
            Log.debug("Pre-created unused conversation: \(group.id)")
        } catch {
            let isCancellation = error is CancellationError
            if isCancellation {
                Log.debug("Unused conversation preparation cancelled post-publish; rolling back.")
            } else {
                Log.error("Failed to finish unused conversation setup post-publish: \(error). Rolling back to keep state consistent.")
                lastPreparationFailure = Date()
            }
            // Log leave-group failures at error level so telemetry can
            // detect orphaned MLS groups (live on the XMTP network with no
            // local record). Low-probability — we're the sole member and
            // the group hasn't been shared yet — but a persistent stream
            // of these would point to a libxmtp reconnect issue worth
            // investigating. Group id is included so the orphan can be
            // matched against XMTP-side state if needed.
            do {
                try await group.leaveGroup()
            } catch {
                Log.error("Failed to leave unused-conversation group \(group.id) after post-publish rollback: \(error). Group may remain live on the XMTP network.")
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
        }
    }

    /// Writes the freshly-published group to GRDB in one pass, using the real
    /// invite tag from the MLS group. Called once per preparation after
    /// `publish()` and `ensureInviteTag()` have resolved. Treats a pre-existing
    /// row with the same id as a benign collision (carry its local state, flip
    /// `isUnused` back to true) rather than a surprise — callers of the cache
    /// may have touched the row in flight.
    private func writeUnusedConversation(
        conversation: XMTPiOS.Group,
        inboxId: String,
        databaseWriter: any DatabaseWriter
    ) async throws -> DBConversation {
        let conversationId = conversation.id
        let creatorInboxId = try await conversation.creatorInboxId()
        let inviteTag = try conversation.inviteTag

        return try await databaseWriter.write { db in
            try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)

            let dbConversation: DBConversation
            if let existing = try DBConversation.fetchOne(db, key: conversationId) {
                dbConversation = existing
                    .with(isUnused: true)
                    .with(inviteTag: inviteTag)
                try dbConversation.update(db)
            } else {
                dbConversation = DBConversation(
                    id: conversationId,
                    clientConversationId: conversationId,
                    inviteTag: inviteTag,
                    creatorId: creatorInboxId,
                    kind: .group,
                    consent: .allowed,
                    createdAt: conversation.createdAt,
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
                hidesInviteCard: false
            ).save(db, onConflict: .ignore)

            return dbConversation
        }
    }
}
