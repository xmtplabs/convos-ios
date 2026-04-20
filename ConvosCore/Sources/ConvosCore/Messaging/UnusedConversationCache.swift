import Foundation
import GRDB
@preconcurrency import XMTPiOS

// MARK: - UnusedConversationCacheProtocol

/// Pre-creates an XMTP group on the authorized messaging service so the first
/// "new conversation" a user taps into is already published. The pre-created
/// group lives as a `DBConversation` row with `isUnused = true`; callers either
/// consume one via `consumeUnusedConversationId` or get `nil` and create a
/// conversation on demand.
public protocol UnusedConversationCacheProtocol: Actor {
    /// Schedules pre-creation of an unused conversation on `service`. Idempotent:
    /// no-op if a preparation task is already in flight or an unused row already
    /// exists in the DB.
    func prepareUnusedConversation(
        service: any MessagingServiceProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async

    /// Atomically claims any available unused conversation: flips `isUnused`
    /// to `false` and returns its id, or returns `nil` if no unused row exists.
    func consumeUnusedConversationId(
        databaseWriter: any DatabaseWriter
    ) async -> String?

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
        let now = Date()
        do {
            return try await databaseWriter.write { db -> String? in
                guard let row = try DBConversation
                    .filter(DBConversation.Columns.isUnused == true)
                    .fetchOne(db) else {
                    return nil
                }
                try db.execute(
                    sql: "UPDATE conversation SET isUnused = ?, createdAt = ? WHERE id = ?",
                    arguments: [false, now, row.id]
                )
                return row.id
            }
        } catch {
            Log.error("Failed to consume unused conversation: \(error)")
            return nil
        }
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
        do {
            return try await databaseReader.read { db in
                try DBConversation
                    .filter(DBConversation.Columns.isUnused == true)
                    .fetchCount(db) > 0
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

        let inboxId: String
        let group: XMTPiOS.Group
        do {
            let inboxReady = try await service.sessionStateManager.waitForInboxReadyResult()
            let client = inboxReady.client
            inboxId = client.inboxId
            nonisolated(unsafe) let optimisticConversation = try client.prepareConversation()
            try await optimisticConversation.publish()
            guard let xmtpGroup = optimisticConversation as? XMTPiOS.Group else {
                Log.error("Pre-created conversation was not a group; abandoning")
                lastPreparationFailure = Date()
                return
            }
            group = xmtpGroup
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
            try await group.ensureInviteTag()
            do {
                try await group.ensureImageEncryptionKey()
            } catch {
                Log.warning("Failed to generate image encryption key for unused conversation: \(error). Will retry on first image upload.")
            }

            let dbConversation = try await writeUnusedConversation(
                conversation: group,
                inboxId: inboxId,
                databaseWriter: databaseWriter
            )
            dbRowWritten = true

            let inviteWriter = InviteWriter(
                identityStore: identityStore,
                databaseWriter: databaseWriter
            )
            _ = try await inviteWriter.generate(for: dbConversation)

            lastPreparationFailure = nil
            Log.debug("Pre-created unused conversation: \(group.id)")
        } catch {
            Log.error("Failed to finish unused conversation setup post-publish: \(error). Rolling back to keep state consistent.")
            lastPreparationFailure = Date()
            try? await group.leaveGroup()
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
                    hasHadVerifiedAssistant: false
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
            ).save(db)

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
                pinnedOrder: nil
            ).save(db, onConflict: .ignore)

            return dbConversation
        }
    }
}
