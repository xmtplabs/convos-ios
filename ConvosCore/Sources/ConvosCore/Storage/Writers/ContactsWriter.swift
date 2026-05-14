import Foundation
import GRDB

/// Snapshot of profile fields used when upserting a contact. All fields are
/// optional — callers pass whatever they currently have for the inbox.
public struct ContactProfileSnapshot: Sendable, Hashable {
    public let displayName: String?
    public let avatarURL: String?
    public let bio: String?
    public let profileUpdatedAt: Date?

    public init(
        displayName: String? = nil,
        avatarURL: String? = nil,
        bio: String? = nil,
        profileUpdatedAt: Date? = nil
    ) {
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.bio = bio
        self.profileUpdatedAt = profileUpdatedAt
    }
}

public protocol ContactsWriterProtocol: Sendable {
    /// Idempotent upsert. If the contact already exists, the immutable
    /// identity columns (`addedAt`, `addedViaConversationId`) are preserved
    /// and only the profile snapshot is updated subject to most-recent-wins.
    func upsertContact(
        inboxId: String,
        addedViaConversationId: String?,
        profile: ContactProfileSnapshot
    ) async throws

    /// Most-recent-wins profile update. Applied only if the incoming
    /// `profileUpdatedAt` is newer than the stored value (or the stored value
    /// is nil). Falls back to local now when the source has no timestamp so
    /// callers can still seed initial profile data.
    func updateProfileIfNewer(
        inboxId: String,
        profile: ContactProfileSnapshot
    ) async throws
}

final class ContactsWriter: ContactsWriterProtocol, @unchecked Sendable {
    private let databaseWriter: any DatabaseWriter

    init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    func upsertContact(
        inboxId: String,
        addedViaConversationId: String?,
        profile: ContactProfileSnapshot
    ) async throws {
        try await databaseWriter.write { db in
            try Self.upsert(
                db: db,
                inboxId: inboxId,
                addedViaConversationId: addedViaConversationId,
                profile: profile
            )
        }
    }

    func updateProfileIfNewer(
        inboxId: String,
        profile: ContactProfileSnapshot
    ) async throws {
        try await databaseWriter.write { db in
            guard let existing = try DBContact.fetchOne(db, key: inboxId) else {
                // No contact row to update; profile updates for non-contacts
                // are intentionally dropped (the contacts feature is action-
                // gated and we never auto-add from a profile event alone).
                return
            }
            let merged = Self.mergeProfile(into: existing, with: profile)
            try merged.save(db)
        }
    }

    fileprivate static func upsert(
        db: Database,
        inboxId: String,
        addedViaConversationId: String?,
        profile: ContactProfileSnapshot
    ) throws {
        if let existing = try DBContact.fetchOne(db, key: inboxId) {
            // Identity columns (addedAt, addedViaConversationId) are
            // intentionally preserved on re-upsert.
            let merged = mergeProfile(into: existing, with: profile)
            try merged.save(db)
            return
        }

        let now = Date()
        let row = DBContact(
            inboxId: inboxId,
            addedAt: now,
            addedViaConversationId: addedViaConversationId,
            displayName: profile.displayName,
            avatarURL: profile.avatarURL,
            bio: profile.bio,
            profileUpdatedAt: profile.profileUpdatedAt ?? now
        )
        try row.save(db)
        Log.debug("Inserted new contact for inboxId=\(inboxId) via=\(addedViaConversationId ?? "nil")")
    }

    private static func mergeProfile(
        into existing: DBContact,
        with profile: ContactProfileSnapshot
    ) -> DBContact {
        let incomingTimestamp: Date = profile.profileUpdatedAt ?? Date()
        let storedTimestamp: Date? = existing.profileUpdatedAt
        let shouldApply: Bool
        if let storedTimestamp {
            shouldApply = incomingTimestamp >= storedTimestamp
        } else {
            shouldApply = true
        }
        guard shouldApply else { return existing }

        // We only overwrite a stored field if the incoming value is non-nil.
        // This lets profile snapshots that carry only some fields (e.g. just
        // an avatar update) merge cleanly without clobbering the others.
        let mergedName = profile.displayName ?? existing.displayName
        let mergedAvatar = profile.avatarURL ?? existing.avatarURL
        let mergedBio = profile.bio ?? existing.bio
        return existing.with(
            displayName: mergedName,
            avatarURL: mergedAvatar,
            bio: mergedBio,
            profileUpdatedAt: incomingTimestamp
        )
    }
}

/// Internal helpers for in-transaction upserts used by the sync coordinator
/// (which composes its own multi-row write).
extension ContactsWriter {
    static func upsertContactInTransaction(
        db: Database,
        inboxId: String,
        addedViaConversationId: String?,
        profile: ContactProfileSnapshot
    ) throws {
        try upsert(
            db: db,
            inboxId: inboxId,
            addedViaConversationId: addedViaConversationId,
            profile: profile
        )
    }
}
