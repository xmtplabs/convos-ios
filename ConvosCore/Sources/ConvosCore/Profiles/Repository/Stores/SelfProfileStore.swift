import Foundation
import GRDB

/// Persistence for the current user's identity, backed by the `myProfile` table
/// (`DBMyProfile`) - the single source of truth the "My Info" UI also writes.
/// Keyed per inbox. Writes only touch name/metadata and preserve the existing
/// image fields atomically, so this accessor and `MyGlobalProfileWriter` (which
/// owns the image) can share the table without clobbering each other.
protocol SelfProfileStoreProtocol: Sendable {
    func save(_ profile: DBMyProfile) async throws
    func load() async throws -> DBMyProfile?
    func clear() async throws

    /// Applies the edit to the stored row atomically - read, apply, write in
    /// one transaction - starting from a blank row when none exists, and
    /// returns the persisted result. The only safe way to edit name/metadata:
    /// basing the edit on a snapshot read before an `await` lets two concurrent
    /// edits (a rename and an automatic metadata publish) start from the same
    /// stale row and silently revert each other's field.
    func update(_ edit: SelfProfileEdit, updatedAt: Date) async throws -> DBMyProfile

    /// The current user's conversation-scoped metadata map (cloud connection
    /// grants, agent timezone) for one conversation, or nil when none was ever
    /// published there. Scoped keys are merged over the global metadata at send
    /// time; they never live in `DBMyProfile.metadata`. Takes the inbox id
    /// explicitly (unlike `load`) so a publish that already resolved the self
    /// inbox cannot silently read a different account's rows if the provider's
    /// answer changes mid-flight.
    func scopedMetadata(inboxId: String, conversationId: String) async throws -> ProfileMetadata?

    /// Persists the conversation-scoped metadata map for one conversation.
    /// A nil or empty map deletes the row.
    func saveScopedMetadata(_ metadata: ProfileMetadata?, inboxId: String, conversationId: String, updatedAt: Date) async throws
}

final class GRDBSelfProfileStore: SelfProfileStoreProtocol {
    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader
    private let selfInboxIdProvider: @Sendable () async -> String?

    init(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        selfInboxIdProvider: @escaping @Sendable () async -> String?
    ) {
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.selfInboxIdProvider = selfInboxIdProvider
    }

    /// Persists name/metadata for `profile.inboxId`, preserving any existing
    /// image fields in the same transaction so a self name/metadata publish
    /// never wipes the user's photo.
    func save(_ profile: DBMyProfile) async throws {
        try await databaseWriter.write { db in
            let existing = try DBMyProfile
                .filter(DBMyProfile.Columns.inboxId == profile.inboxId)
                .fetchOne(db)
            let merged = DBMyProfile(
                inboxId: profile.inboxId,
                name: profile.name,
                imageData: existing?.imageData,
                imageAssetIdentifier: existing?.imageAssetIdentifier,
                imageContentDigest: existing?.imageContentDigest,
                metadata: profile.metadata,
                updatedAt: profile.updatedAt
            )
            try merged.save(db)
        }
    }

    func load() async throws -> DBMyProfile? {
        guard let inboxId = await selfInboxIdProvider() else { return nil }
        return try await databaseReader.read { db in
            try DBMyProfile.filter(DBMyProfile.Columns.inboxId == inboxId).fetchOne(db)
        }
    }

    func update(_ edit: SelfProfileEdit, updatedAt: Date) async throws -> DBMyProfile {
        guard let inboxId = await selfInboxIdProvider() else {
            throw SelfProfileStoreError.selfInboxUnavailable
        }
        return try await databaseWriter.write { db in
            let existing = try DBMyProfile
                .filter(DBMyProfile.Columns.inboxId == inboxId)
                .fetchOne(db) ?? DBMyProfile(inboxId: inboxId)
            // `applied(to:)` carries the image fields from the row read inside
            // this same transaction, so the edit cannot wipe the photo either.
            let updated = edit.applied(to: existing, updatedAt: updatedAt)
            try updated.save(db)
            return updated
        }
    }

    func clear() async throws {
        guard let inboxId = await selfInboxIdProvider() else { return }
        try await databaseWriter.write { db in
            _ = try DBMyProfile.filter(DBMyProfile.Columns.inboxId == inboxId).deleteAll(db)
            _ = try DBSelfConversationMetadata
                .filter(DBSelfConversationMetadata.Columns.inboxId == inboxId)
                .deleteAll(db)
        }
    }

    func scopedMetadata(inboxId: String, conversationId: String) async throws -> ProfileMetadata? {
        try await databaseReader.read { db in
            try DBSelfConversationMetadata
                .filter(DBSelfConversationMetadata.Columns.inboxId == inboxId)
                .filter(DBSelfConversationMetadata.Columns.conversationId == conversationId)
                .fetchOne(db)?.metadata
        }
    }

    func saveScopedMetadata(_ metadata: ProfileMetadata?, inboxId: String, conversationId: String, updatedAt: Date) async throws {
        try await databaseWriter.write { db in
            guard let metadata, !metadata.isEmpty else {
                _ = try DBSelfConversationMetadata
                    .filter(DBSelfConversationMetadata.Columns.inboxId == inboxId)
                    .filter(DBSelfConversationMetadata.Columns.conversationId == conversationId)
                    .deleteAll(db)
                return
            }
            try DBSelfConversationMetadata(
                inboxId: inboxId,
                conversationId: conversationId,
                metadata: metadata,
                updatedAt: updatedAt
            ).save(db)
        }
    }
}

actor InMemorySelfProfileStore: SelfProfileStoreProtocol {
    private let inboxId: String
    private var current: DBMyProfile?
    private var scopedByInbox: [String: [String: ProfileMetadata]] = [:]

    init(inboxId: String = "me") {
        self.inboxId = inboxId
    }

    func save(_ profile: DBMyProfile) {
        current = profile
    }

    func load() -> DBMyProfile? {
        current
    }

    func update(_ edit: SelfProfileEdit, updatedAt: Date) -> DBMyProfile {
        let existing = current ?? DBMyProfile(inboxId: inboxId)
        let updated = edit.applied(to: existing, updatedAt: updatedAt)
        current = updated
        return updated
    }

    func clear() {
        current = nil
        scopedByInbox = [:]
    }

    func scopedMetadata(inboxId: String, conversationId: String) -> ProfileMetadata? {
        scopedByInbox[inboxId]?[conversationId]
    }

    func saveScopedMetadata(_ metadata: ProfileMetadata?, inboxId: String, conversationId: String, updatedAt: Date) {
        guard let metadata, !metadata.isEmpty else {
            scopedByInbox[inboxId]?[conversationId] = nil
            return
        }
        scopedByInbox[inboxId, default: [:]][conversationId] = metadata
    }
}

enum SelfProfileStoreError: Error {
    case selfInboxUnavailable
}
