import Foundation
import GRDB
@preconcurrency import XMTPiOS

// MARK: - UnusedConversationCacheProtocol

/// Pre-creates an XMTP group on the authorized messaging service so the first
/// "new conversation" a user taps into is already published. Consumers either
/// get a cached conversation ID back or nil — in which case they create the
/// conversation on demand.
public protocol UnusedConversationCacheProtocol: Actor {
    /// Schedules pre-creation of an unused conversation on `service`. Idempotent.
    func prepareUnusedConversation(
        service: any MessagingServiceProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async

    /// Returns the pre-created conversation ID if one is cached and valid;
    /// the returned conversation is marked `isUnused = false` atomically.
    /// Returns nil if no conversation is cached or the cached one is stale.
    func consumeUnusedConversationId(
        databaseWriter: any DatabaseWriter
    ) async -> String?

    /// Whether the given conversation ID refers to the currently cached
    /// unused conversation.
    func isUnusedConversation(_ conversationId: String) -> Bool

    /// Whether the cache has a pre-created conversation ready to consume.
    func hasUnusedConversation() -> Bool

    /// Clears the cached conversation pointer from the keychain. Does not
    /// touch the database row.
    func clearUnusedFromKeychain()
}

// MARK: - UnusedConversationCacheError

enum UnusedConversationCacheError: Error {
    case invalidConversationType
    case identityMismatch
}

// MARK: - UnusedConversationCache

public actor UnusedConversationCache: UnusedConversationCacheProtocol {
    private let keychainService: any KeychainServiceProtocol
    private let identityStore: any KeychainIdentityStoreProtocol
    private var isCreating: Bool = false
    private var backgroundCreationTask: Task<Void, Never>?
    private var lastPreparationFailure: Date?
    private static let preparationCooldown: TimeInterval = 30

    public init(
        keychainService: any KeychainServiceProtocol = KeychainService(),
        identityStore: any KeychainIdentityStoreProtocol
    ) {
        self.keychainService = keychainService
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
        if getUnusedConversationIdFromKeychain() != nil {
            Log.debug("Unused conversation already cached, skipping...")
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
            await self.runPreparation(
                service: service,
                databaseWriter: databaseWriter,
                databaseReader: databaseReader,
                environment: environment
            )
        }
    }

    public func consumeUnusedConversationId(
        databaseWriter: any DatabaseWriter
    ) async -> String? {
        guard let conversationId = getUnusedConversationIdFromKeychain() else {
            return nil
        }

        // Mark the DB row as used *before* clearing the keychain pointer.
        // If the DB write throws and we've already cleared the keychain,
        // the conversation becomes an orphan: the DB still says `isUnused
        // = true` (so the conversation list filters it out) and the
        // keychain no longer points to it, so nothing in the app knows
        // the row exists. Ordering: succeed the DB write first, then
        // drop the keychain entry.
        let existedAndMarked: Bool
        do {
            existedAndMarked = try await markConversationAsUsed(
                conversationId: conversationId,
                databaseWriter: databaseWriter
            )
        } catch {
            Log.error("Failed to consume unused conversation \(conversationId): \(error). Leaving keychain entry intact for retry.")
            return nil
        }

        guard existedAndMarked else {
            // Keychain pointed to a row that's not in the DB anymore;
            // the keychain entry is the stale one and safe to drop.
            Log.warning("Unused conversation \(conversationId) missing from database; dropping stale cache entry")
            clearUnusedFromKeychain()
            return nil
        }

        clearUnusedFromKeychain()
        Log.debug("Consumed unused conversation: \(conversationId)")
        return conversationId
    }

    public func isUnusedConversation(_ conversationId: String) -> Bool {
        getUnusedConversationIdFromKeychain() == conversationId
    }

    public func hasUnusedConversation() -> Bool {
        getUnusedConversationIdFromKeychain() != nil
    }

    public func clearUnusedFromKeychain() {
        try? keychainService.delete(account: KeychainAccount.unusedConversation)
    }

    // MARK: - Private

    private func runPreparation(
        service: any MessagingServiceProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {
        guard !isCreating else { return }
        isCreating = true
        defer {
            isCreating = false
            backgroundCreationTask = nil
        }

        do {
            let inboxReady = try await service.sessionStateManager.waitForInboxReadyResult()
            let client = inboxReady.client
            let inboxId = client.inboxId

            guard let identity = try await identityStore.load(),
                  identity.inboxId == inboxId else {
                throw UnusedConversationCacheError.identityMismatch
            }

            nonisolated(unsafe) let optimisticConversation = try client.prepareConversation()
            let conversationId = optimisticConversation.id

            try await optimisticConversation.publish()

            guard let group = optimisticConversation as? XMTPiOS.Group else {
                throw UnusedConversationCacheError.invalidConversationType
            }

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

            let inviteWriter = InviteWriter(
                identityStore: identityStore,
                databaseWriter: databaseWriter
            )
            _ = try await inviteWriter.generate(for: dbConversation)

            saveUnusedConversationIdToKeychain(conversationId)
            lastPreparationFailure = nil
            Log.debug("Pre-created unused conversation: \(conversationId)")
        } catch {
            Log.error("Failed to pre-create unused conversation: \(error)")
            lastPreparationFailure = Date()
        }
    }

    /// Marks the conversation as consumed (`isUnused = false`) and updates
    /// its `createdAt` to now. Returns `true` if a row was updated.
    private func markConversationAsUsed(
        conversationId: String,
        databaseWriter: any DatabaseWriter
    ) async throws -> Bool {
        let now = Date()
        return try await databaseWriter.write { db in
            try db.execute(
                sql: "UPDATE conversation SET isUnused = ?, createdAt = ? WHERE id = ?",
                arguments: [false, now, conversationId]
            )
            return db.changesCount > 0
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

    private func getUnusedConversationIdFromKeychain() -> String? {
        try? keychainService.retrieveString(account: KeychainAccount.unusedConversation)
    }

    private func saveUnusedConversationIdToKeychain(_ conversationId: String) {
        do {
            try keychainService.saveString(conversationId, account: KeychainAccount.unusedConversation)
        } catch {
            Log.error("Failed to save unused conversation to keychain: \(error)")
        }
    }
}
