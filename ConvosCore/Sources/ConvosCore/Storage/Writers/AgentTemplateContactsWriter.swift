import Foundation
import GRDB

/// Snapshot of agent-template profile fields used when upserting an
/// agent-template contact. Mirrors `ContactProfileSnapshot`: a timestamped
/// snapshot (`profileUpdatedAt != nil`) is treated as one authoritative unit
/// that wholesale-replaces every profile field on the stored row; an
/// untimestamped snapshot is a fill-defaults payload that only seeds a new
/// row and never updates an existing one.
public struct AgentTemplateContactSnapshot: Sendable, Hashable {
    public let displayName: String?
    public let emoji: String?
    public let descriptionText: String?
    public let publishedURL: String?
    public let avatarURL: String?
    public let agentVerification: AgentVerification?
    public let profileUpdatedAt: Date?

    public init(
        displayName: String? = nil,
        emoji: String? = nil,
        descriptionText: String? = nil,
        publishedURL: String? = nil,
        avatarURL: String? = nil,
        agentVerification: AgentVerification? = nil,
        profileUpdatedAt: Date? = nil
    ) {
        self.displayName = displayName
        self.emoji = emoji
        self.descriptionText = descriptionText
        self.publishedURL = publishedURL
        self.avatarURL = avatarURL
        self.agentVerification = agentVerification
        self.profileUpdatedAt = profileUpdatedAt
    }
}

public protocol AgentTemplateContactsWriterProtocol: Sendable {
    /// Idempotent upsert. If the contact already exists, the immutable
    /// identity columns (`addedAt`, `addedViaConversationId`) are preserved
    /// and the profile snapshot is applied subject to most-recent-wins.
    func upsert(
        templateId: String,
        addedViaConversationId: String?,
        profile: AgentTemplateContactSnapshot
    ) async throws

    /// Removes the agent-template contact. No-op when `templateId` has no
    /// row. A still-shared conversation re-adds it on the next membership
    /// sync - the same eventual-consistency story as human contacts.
    func remove(templateId: String) async throws
}

final class AgentTemplateContactsWriter: AgentTemplateContactsWriterProtocol, @unchecked Sendable {
    private let databaseWriter: any DatabaseWriter

    init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    func upsert(
        templateId: String,
        addedViaConversationId: String?,
        profile: AgentTemplateContactSnapshot
    ) async throws {
        try await databaseWriter.write { db in
            try Self.upsert(
                db: db,
                templateId: templateId,
                addedViaConversationId: addedViaConversationId,
                profile: profile
            )
        }
    }

    func remove(templateId: String) async throws {
        _ = try await databaseWriter.write { db in
            try DBAgentTemplateContact.deleteOne(db, key: templateId)
        }
    }

    fileprivate static func upsert(
        db: Database,
        templateId: String,
        addedViaConversationId: String?,
        profile: AgentTemplateContactSnapshot
    ) throws {
        if let existing = try DBAgentTemplateContact.fetchOne(db, key: templateId) {
            // Identity columns (addedAt, addedViaConversationId) are
            // preserved on re-upsert. The profile snapshot is applied only
            // if it carries a `profileUpdatedAt` newer than the stored one;
            // untimestamped re-upserts leave the existing row untouched.
            guard let merged = replacingProfile(of: existing, with: profile) else {
                return
            }
            try merged.save(db)
            return
        }

        let now = Date()
        let row = DBAgentTemplateContact(
            templateId: templateId,
            addedAt: now,
            addedViaConversationId: addedViaConversationId,
            displayName: profile.displayName,
            emoji: profile.emoji,
            descriptionText: profile.descriptionText,
            publishedURL: profile.publishedURL,
            avatarURL: profile.avatarURL,
            agentVerification: profile.agentVerification,
            profileUpdatedAt: profile.profileUpdatedAt ?? now
        )
        try row.save(db)
        Log.debug("Inserted new agent-template contact for templateId=\(templateId)")
    }

    /// Returns `existing` with its profile fields replaced by `profile` if
    /// the snapshot should apply; returns `nil` if the caller should leave
    /// the stored row untouched. Mirrors `ContactsWriter.replacingProfile`:
    /// untimestamped snapshots never update an existing row; timestamped
    /// snapshots older than the stored `profileUpdatedAt` are dropped;
    /// newer-or-equal snapshots wholesale-replace every profile field.
    private static func replacingProfile(
        of existing: DBAgentTemplateContact,
        with profile: AgentTemplateContactSnapshot
    ) -> DBAgentTemplateContact? {
        guard let incomingTimestamp = profile.profileUpdatedAt else {
            return nil
        }
        if let stored = existing.profileUpdatedAt, incomingTimestamp < stored {
            return nil
        }
        return existing.replacingProfileFields(with: profile, at: incomingTimestamp)
    }
}

/// In-transaction upsert helper for `ContactSyncCoordinator` (Phase 2.2),
/// which captures agent-template contacts inside the membership-sync
/// transaction. Mirrors `ContactsWriter.upsertContactInTransaction`.
extension AgentTemplateContactsWriter {
    static func upsertInTransaction(
        db: Database,
        templateId: String,
        addedViaConversationId: String?,
        profile: AgentTemplateContactSnapshot
    ) throws {
        try upsert(
            db: db,
            templateId: templateId,
            addedViaConversationId: addedViaConversationId,
            profile: profile
        )
    }
}
