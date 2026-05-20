import Foundation
import GRDB

/// Local contact record. Keyed by `inboxId` under the single-inbox identity model
/// (ADR-011). Stores a denormalized "global default profile" snapshot updated
/// most-recent-wins as new profile data arrives for the contact.
///
/// `blockedAt` is non-nil if the local user has blocked this contact. Blocked
/// contacts continue to appear in the browse list (so the user can find them
/// to unblock); inbound conversation filtering and the picker use the column
/// to gate behavior.
struct DBContact: Codable, FetchableRecord, PersistableRecord, Hashable, Identifiable {
    static let databaseTableName: String = "contact"

    enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let addedAt: Column = Column(CodingKeys.addedAt)
        static let addedViaConversationId: Column = Column(CodingKeys.addedViaConversationId)
        static let displayName: Column = Column(CodingKeys.displayName)
        static let avatarURL: Column = Column(CodingKeys.avatarURL)
        static let avatarSalt: Column = Column(CodingKeys.avatarSalt)
        static let avatarNonce: Column = Column(CodingKeys.avatarNonce)
        static let avatarKey: Column = Column(CodingKeys.avatarKey)
        static let profileUpdatedAt: Column = Column(CodingKeys.profileUpdatedAt)
        static let blockedAt: Column = Column(CodingKeys.blockedAt)
        static let agentVerification: Column = Column(CodingKeys.agentVerification)
    }

    var id: String { inboxId }

    let inboxId: String
    let addedAt: Date
    let addedViaConversationId: String?

    var displayName: String?
    var avatarURL: String?
    /// Salt/nonce/key for decrypting the encrypted avatar at `avatarURL`.
    /// Mirrored from the most-recently-observed `DBMemberProfile` via
    /// `mirrorMemberProfileToContactInTransaction` so contact-list and
    /// contact-card renderers can decrypt the image without going back to
    /// the per-conversation profile. `nil` means we have not observed
    /// encryption material yet (e.g., the only profile signal we got was a
    /// name-only update).
    var avatarSalt: Data?
    var avatarNonce: Data?
    var avatarKey: Data?
    var profileUpdatedAt: Date?
    var blockedAt: Date?
    /// Agent verification snapshot for this contact. `nil` means we have not
    /// observed an agent signal for this inbox yet; `.unverified` /
    /// `.verified(...)` are observed states. The unified contact card shows
    /// agent rows iff `agentVerification?.isVerified == true`. A newer
    /// snapshot with `nil` `agentVerification` wholesale-clears the stored
    /// verification (see `ContactsWriter.replacingProfile(of:with:)`).
    var agentVerification: AgentVerification?

    init(
        inboxId: String,
        addedAt: Date,
        addedViaConversationId: String?,
        displayName: String? = nil,
        avatarURL: String? = nil,
        avatarSalt: Data? = nil,
        avatarNonce: Data? = nil,
        avatarKey: Data? = nil,
        profileUpdatedAt: Date? = nil,
        blockedAt: Date? = nil,
        agentVerification: AgentVerification? = nil
    ) {
        self.inboxId = inboxId
        self.addedAt = addedAt
        self.addedViaConversationId = addedViaConversationId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.avatarSalt = avatarSalt
        self.avatarNonce = avatarNonce
        self.avatarKey = avatarKey
        self.profileUpdatedAt = profileUpdatedAt
        self.blockedAt = blockedAt
        self.agentVerification = agentVerification
    }
}

extension DBContact {
    /// Returns a copy of `self` with every profile field replaced by the
    /// snapshot's values (including `nil`s) and `profileUpdatedAt` set to
    /// `timestamp`. Identity columns (`inboxId`, `addedAt`,
    /// `addedViaConversationId`) and `blockedAt` are preserved. Used by
    /// `ContactsWriter.replacingProfile(of:with:)`.
    func replacingProfileFields(
        with snapshot: ContactProfileSnapshot,
        at timestamp: Date
    ) -> DBContact {
        DBContact(
            inboxId: inboxId,
            addedAt: addedAt,
            addedViaConversationId: addedViaConversationId,
            displayName: snapshot.displayName,
            avatarURL: snapshot.avatarURL,
            avatarSalt: snapshot.avatarSalt,
            avatarNonce: snapshot.avatarNonce,
            avatarKey: snapshot.avatarKey,
            profileUpdatedAt: timestamp,
            blockedAt: blockedAt,
            agentVerification: snapshot.agentVerification
        )
    }

    func with(blockedAt: Date?) -> DBContact {
        DBContact(
            inboxId: inboxId,
            addedAt: addedAt,
            addedViaConversationId: addedViaConversationId,
            displayName: displayName,
            avatarURL: avatarURL,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce,
            avatarKey: avatarKey,
            profileUpdatedAt: profileUpdatedAt,
            blockedAt: blockedAt,
            agentVerification: agentVerification
        )
    }
}
