import ConvosAppData
import Foundation
import GRDB

enum DBMemberKind: String, Codable, Hashable {
    case agent
    case verifiedConvos = "agent:convos"
    case verifiedUserOAuth = "agent:user-oauth"

    var isAgent: Bool { true }

    var agentVerification: AgentVerification {
        switch self {
        case .agent:
            return .unverified
        case .verifiedConvos:
            return .verified(.convos)
        case .verifiedUserOAuth:
            return .verified(.userOAuth)
        }
    }

    static func from(agentVerification: AgentVerification) -> DBMemberKind {
        switch agentVerification {
        case .unverified:
            return .agent
        case .verified(.convos):
            return .verifiedConvos
        case .verified(.userOAuth):
            return .verifiedUserOAuth
        case .verified(.unknown):
            return .agent
        }
    }
}

struct DBMemberProfile: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "memberProfile"

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let name: Column = Column(CodingKeys.name)
        static let avatar: Column = Column(CodingKeys.avatar)
        static let avatarSalt: Column = Column(CodingKeys.avatarSalt)
        static let avatarNonce: Column = Column(CodingKeys.avatarNonce)
        static let avatarKey: Column = Column(CodingKeys.avatarKey)
        static let avatarLastRenewed: Column = Column(CodingKeys.avatarLastRenewed)
        static let imageSourceAssetIdentifier: Column = Column(CodingKeys.imageSourceAssetIdentifier)
        static let imageSourceContentDigest: Column = Column(CodingKeys.imageSourceContentDigest)
        static let memberKind: Column = Column(CodingKeys.memberKind)
        static let metadata: Column = Column(CodingKeys.metadata)
        static let profileUpdatedAt: Column = Column(CodingKeys.profileUpdatedAt)
        static let publishedNameDigest: Column = Column(CodingKeys.publishedNameDigest)
        static let publishedAvatarDigest: Column = Column(CodingKeys.publishedAvatarDigest)
    }

    let conversationId: String
    let inboxId: String
    let name: String?
    let avatar: String?
    let avatarSalt: Data?
    let avatarNonce: Data?
    let avatarKey: Data?
    let avatarLastRenewed: Date?
    /// Vestigial. Superseded by `imageSourceContentDigest` for change detection. Not read or
    /// written by current code; the column remains so previously-applied migrations stay
    /// consistent with the registered migration list.
    let imageSourceAssetIdentifier: String?
    /// Stable, content-addressed digest of the source image that was uploaded for this
    /// member's avatar (set when activate-sync uploads from the global profile). Compared
    /// against `DBMyProfile.imageContentDigest` to decide whether a re-upload is needed.
    let imageSourceContentDigest: String?
    let memberKind: DBMemberKind?
    let metadata: ProfileMetadata?
    /// Recency guard for inbound profile writes: the `sentAt` of the most recent
    /// profile message applied to this row. Inbound applies are dropped when the
    /// incoming message is older than this (most-recent-wins, mirroring
    /// `DBContact.profileUpdatedAt`). nil means no message-sourced stamp yet, so
    /// any inbound write may apply. Local edits stamp this with the wall clock.
    let profileUpdatedAt: Date?
    /// Digest of the display name last successfully published (sent as a
    /// ProfileUpdate to the group) for the local user's own profile in this
    /// conversation. Activate-sync compares this against the global profile so a
    /// failed publish (marker stays stale) is retried. nil for other members and
    /// for never-published rows.
    let publishedNameDigest: String?
    /// Digest of the avatar source last successfully published for the local
    /// user's own profile in this conversation. Compared against
    /// `DBMyProfile.imageContentDigest`; nil means no avatar was confirmed
    /// published (or it was confirmed cleared).
    let publishedAvatarDigest: String?

    var isAgent: Bool {
        memberKind?.isAgent ?? false
    }

    var agentVerification: AgentVerification {
        memberKind?.agentVerification ?? .unverified
    }

    init(
        conversationId: String,
        inboxId: String,
        name: String?,
        avatar: String?,
        avatarSalt: Data? = nil,
        avatarNonce: Data? = nil,
        avatarKey: Data? = nil,
        avatarLastRenewed: Date? = nil,
        imageSourceAssetIdentifier: String? = nil,
        imageSourceContentDigest: String? = nil,
        memberKind: DBMemberKind? = nil,
        metadata: ProfileMetadata? = nil,
        profileUpdatedAt: Date? = nil,
        publishedNameDigest: String? = nil,
        publishedAvatarDigest: String? = nil
    ) {
        self.conversationId = conversationId
        self.inboxId = inboxId
        self.name = name
        self.avatar = avatar
        self.avatarSalt = avatarSalt
        self.avatarNonce = avatarNonce
        self.avatarKey = avatarKey
        self.avatarLastRenewed = avatarLastRenewed
        self.imageSourceAssetIdentifier = imageSourceAssetIdentifier
        self.imageSourceContentDigest = imageSourceContentDigest
        self.memberKind = memberKind
        self.metadata = metadata
        self.profileUpdatedAt = profileUpdatedAt
        self.publishedNameDigest = publishedNameDigest
        self.publishedAvatarDigest = publishedAvatarDigest
    }

    static let memberForeignKey: ForeignKey = ForeignKey([Columns.inboxId], to: [DBMember.Columns.inboxId])
    static let conversationForeignKey: ForeignKey = ForeignKey([Columns.conversationId], to: [DBConversation.Columns.id])

    static let member: BelongsToAssociation<DBMemberProfile, DBMember> = belongsTo(
        DBMember.self,
        using: memberForeignKey
    )

    static let conversation: BelongsToAssociation<DBMemberProfile, DBConversation> = belongsTo(
        DBConversation.self,
        using: conversationForeignKey
    )
}

extension DBMemberProfile {
    static func fetchOne(
        _ db: Database,
        conversationId: String,
        inboxId: String
    ) throws -> DBMemberProfile? {
        try fetchOne(
            db,
            key: [
                Columns.conversationId.name: conversationId,
                Columns.inboxId.name: inboxId
            ]
        )
    }

    static func fetchAll(
        _ db: Database,
        conversationId: String,
        inboxIds: [String]
    ) throws -> [DBMemberProfile] {
        let keys = inboxIds.map {
            [
                Columns.conversationId.name: conversationId,
                Columns.inboxId.name: $0
            ]
        }
        return try fetchAll(db, keys: keys)
    }

    func with(name: String?) -> DBMemberProfile {
        .init(
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: avatarSalt, avatarNonce: avatarNonce, avatarKey: avatarKey,
            avatarLastRenewed: avatarLastRenewed,
            imageSourceAssetIdentifier: imageSourceAssetIdentifier,
            imageSourceContentDigest: imageSourceContentDigest,
            memberKind: memberKind, metadata: metadata,
            profileUpdatedAt: profileUpdatedAt,
            publishedNameDigest: publishedNameDigest,
            publishedAvatarDigest: publishedAvatarDigest
        )
    }

    func with(avatar: String?) -> DBMemberProfile {
        .init(
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: avatarSalt, avatarNonce: avatarNonce, avatarKey: avatarKey,
            avatarLastRenewed: avatarLastRenewed,
            imageSourceAssetIdentifier: imageSourceAssetIdentifier,
            imageSourceContentDigest: imageSourceContentDigest,
            memberKind: memberKind, metadata: metadata,
            profileUpdatedAt: profileUpdatedAt,
            publishedNameDigest: publishedNameDigest,
            publishedAvatarDigest: publishedAvatarDigest
        )
    }

    func with(avatar: String?, salt: Data?, nonce: Data?, key: Data?) -> DBMemberProfile {
        .init(
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: salt, avatarNonce: nonce, avatarKey: key,
            avatarLastRenewed: avatarLastRenewed,
            imageSourceAssetIdentifier: imageSourceAssetIdentifier,
            imageSourceContentDigest: imageSourceContentDigest,
            memberKind: memberKind, metadata: metadata,
            profileUpdatedAt: profileUpdatedAt,
            publishedNameDigest: publishedNameDigest,
            publishedAvatarDigest: publishedAvatarDigest
        )
    }

    func with(avatarLastRenewed: Date?) -> DBMemberProfile {
        .init(
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: avatarSalt, avatarNonce: avatarNonce, avatarKey: avatarKey,
            avatarLastRenewed: avatarLastRenewed,
            imageSourceAssetIdentifier: imageSourceAssetIdentifier,
            imageSourceContentDigest: imageSourceContentDigest,
            memberKind: memberKind, metadata: metadata,
            profileUpdatedAt: profileUpdatedAt,
            publishedNameDigest: publishedNameDigest,
            publishedAvatarDigest: publishedAvatarDigest
        )
    }

    func with(imageSourceContentDigest: String?) -> DBMemberProfile {
        .init(
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: avatarSalt, avatarNonce: avatarNonce, avatarKey: avatarKey,
            avatarLastRenewed: avatarLastRenewed,
            imageSourceAssetIdentifier: imageSourceAssetIdentifier,
            imageSourceContentDigest: imageSourceContentDigest,
            memberKind: memberKind, metadata: metadata,
            profileUpdatedAt: profileUpdatedAt,
            publishedNameDigest: publishedNameDigest,
            publishedAvatarDigest: publishedAvatarDigest
        )
    }

    func with(memberKind: DBMemberKind?) -> DBMemberProfile {
        .init(
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: avatarSalt, avatarNonce: avatarNonce, avatarKey: avatarKey,
            avatarLastRenewed: avatarLastRenewed,
            imageSourceAssetIdentifier: imageSourceAssetIdentifier,
            imageSourceContentDigest: imageSourceContentDigest,
            memberKind: memberKind, metadata: metadata,
            profileUpdatedAt: profileUpdatedAt,
            publishedNameDigest: publishedNameDigest,
            publishedAvatarDigest: publishedAvatarDigest
        )
    }

    func with(metadata: ProfileMetadata?) -> DBMemberProfile {
        .init(
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: avatarSalt, avatarNonce: avatarNonce, avatarKey: avatarKey,
            avatarLastRenewed: avatarLastRenewed,
            imageSourceAssetIdentifier: imageSourceAssetIdentifier,
            imageSourceContentDigest: imageSourceContentDigest,
            memberKind: memberKind, metadata: metadata,
            profileUpdatedAt: profileUpdatedAt,
            publishedNameDigest: publishedNameDigest,
            publishedAvatarDigest: publishedAvatarDigest
        )
    }

    func with(profileUpdatedAt: Date?) -> DBMemberProfile {
        .init(
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: avatarSalt, avatarNonce: avatarNonce, avatarKey: avatarKey,
            avatarLastRenewed: avatarLastRenewed,
            imageSourceAssetIdentifier: imageSourceAssetIdentifier,
            imageSourceContentDigest: imageSourceContentDigest,
            memberKind: memberKind, metadata: metadata,
            profileUpdatedAt: profileUpdatedAt,
            publishedNameDigest: publishedNameDigest,
            publishedAvatarDigest: publishedAvatarDigest
        )
    }

    func with(publishedNameDigest: String?, publishedAvatarDigest: String?) -> DBMemberProfile {
        .init(
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: avatarSalt, avatarNonce: avatarNonce, avatarKey: avatarKey,
            avatarLastRenewed: avatarLastRenewed,
            imageSourceAssetIdentifier: imageSourceAssetIdentifier,
            imageSourceContentDigest: imageSourceContentDigest,
            memberKind: memberKind, metadata: metadata,
            profileUpdatedAt: profileUpdatedAt,
            publishedNameDigest: publishedNameDigest,
            publishedAvatarDigest: publishedAvatarDigest
        )
    }

    /// Applies an inbound encrypted-avatar reference only when its decryption
    /// key is resolvable. Persisting the avatar with a nil key would store a row
    /// the image cache can't decrypt - it renders blank and never self-heals -
    /// so when the key is missing we leave the existing avatar untouched and let
    /// a later message (or the conversation-key backfill on sync) supply it.
    func applyingEncryptedAvatar(url: String, salt: Data, nonce: Data, resolvedKey: Data?) -> DBMemberProfile {
        guard let resolvedKey else { return self }
        return with(avatar: url, salt: salt, nonce: nonce, key: resolvedKey)
    }

    var hasValidEncryptedAvatar: Bool {
        guard let salt = avatarSalt,
              let nonce = avatarNonce,
              avatar != nil else {
            return false
        }
        return salt.count == 32 && nonce.count == 12
    }

    var encryptedImageRef: EncryptedImageRef? {
        guard hasValidEncryptedAvatar,
              let url = avatar,
              let salt = avatarSalt,
              let nonce = avatarNonce else {
            return nil
        }
        var ref = EncryptedImageRef()
        ref.url = url
        ref.salt = salt
        ref.nonce = nonce
        return ref
    }
}

// MARK: - Agent template metadata

extension DBMemberProfile {
    /// The backend `AgentTemplate.id` a template-backed agent was
    /// provisioned from, read from the agent's per-conversation profile
    /// `metadata`. nil for human members and for legacy agents that do
    /// not carry a template.
    var agentTemplateId: String? {
        trimmedMetadata(Constant.templateIdKey)
    }

    /// The shareable web URL for this agent's template (the backend's
    /// `publishedUrl`). Drives the contact card's Share button.
    var agentTemplatePublishedURL: String? {
        trimmedMetadata(Constant.publishedURLKey)
    }

    /// The agent runtime's `instanceId` for this provisioned agent.
    /// Surfaced on the contact card behind an internal-build gate.
    var agentInstanceId: String? {
        metadata?[Constant.instanceIdKey]?.stringValue
    }

    /// The agent template's emoji, when published.
    var agentTemplateEmoji: String? {
        trimmedMetadata(Constant.emojiKey)
    }

    /// Reads a metadata string value, coercing empty / whitespace-only to
    /// nil. The agent runtime can briefly write an empty `templateId` before
    /// its template lookup resolves; persisting `""` would collapse unrelated
    /// agents in the dedup pipeline and fire a fetch on an empty id. Mirrors
    /// `Profile.agentTemplateId`'s coercion so the two accessors agree.
    private func trimmedMetadata(_ key: String) -> String? {
        metadata?[key]?.stringValue.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// The agent template's description, when published.
    var agentTemplateDescription: String? {
        metadata?[Constant.descriptionKey]?.stringValue
    }

    /// True when this member is a template-backed agent - an agent that
    /// published a `templateId` in its profile metadata. Legacy agents
    /// without a templateId return false.
    var isAgentTemplate: Bool {
        isAgent && agentTemplateId != nil
    }

    /// Keys a template-backed agent stamps into its per-conversation
    /// profile `metadata`. Must match the agent runtime's profile
    /// builder.
    private enum Constant {
        static let templateIdKey: String = "templateId"
        static let publishedURLKey: String = "publishedUrl"
        static let emojiKey: String = "emoji"
        static let descriptionKey: String = "description"
        static let instanceIdKey: String = "instanceId"
    }
}
