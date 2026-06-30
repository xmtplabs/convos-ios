import ConvosAppData
import Foundation
import GRDB

/// Canonical per-person identity, keyed by `inboxId`. Single source of truth for
/// a member's display name and agent kind, replacing the identity fields
/// previously read from per-conversation `DBMemberProfile` rows. Avatars live in
/// `DBProfileAvatar` because encryption is per conversation.
///
/// Not wired into rendering or sync yet; introduced ahead of the
/// `ProfilesRepository` that owns it (see
/// docs/plans/2026-06-29-profile-table-implementation.md).
struct DBProfile: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "profile"

    enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let name: Column = Column(CodingKeys.name)
        static let memberKind: Column = Column(CodingKeys.memberKind)
        static let metadata: Column = Column(CodingKeys.metadata)
        static let profileSource: Column = Column(CodingKeys.profileSource)
        static let avatarContentDigest: Column = Column(CodingKeys.avatarContentDigest)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let inboxId: String
    var name: String?
    var memberKind: DBMemberKind?
    var metadata: ProfileMetadata?
    var profileSource: ProfileSource
    /// Reserved for the cross-conversation image-digest optimization (ADR 014).
    /// Always nil until that work lands; declared here so the follow-up needs no
    /// further migration.
    var avatarContentDigest: String?
    var updatedAt: Date

    init(
        inboxId: String,
        name: String? = nil,
        memberKind: DBMemberKind? = nil,
        metadata: ProfileMetadata? = nil,
        profileSource: ProfileSource,
        avatarContentDigest: String? = nil,
        updatedAt: Date
    ) {
        self.inboxId = inboxId
        self.name = name
        self.memberKind = memberKind
        self.metadata = metadata
        self.profileSource = profileSource
        self.avatarContentDigest = avatarContentDigest
        self.updatedAt = updatedAt
    }

    var isAgent: Bool {
        memberKind?.isAgent ?? false
    }

    var agentVerification: AgentVerification {
        memberKind?.agentVerification ?? .unverified
    }
}

extension DBProfile {
    static func fetchOne(_ db: Database, inboxId: String) throws -> DBProfile? {
        try fetchOne(db, key: inboxId)
    }

    static func fetchAll(_ db: Database, inboxIds: [String]) throws -> [DBProfile] {
        try fetchAll(db, keys: inboxIds)
    }
}
