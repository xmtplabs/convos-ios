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
        static let bio: Column = Column(CodingKeys.bio)
        static let profileUpdatedAt: Column = Column(CodingKeys.profileUpdatedAt)
        static let blockedAt: Column = Column(CodingKeys.blockedAt)
    }

    var id: String { inboxId }

    let inboxId: String
    let addedAt: Date
    let addedViaConversationId: String?

    var displayName: String?
    var avatarURL: String?
    var bio: String?
    var profileUpdatedAt: Date?
    var blockedAt: Date?

    init(
        inboxId: String,
        addedAt: Date,
        addedViaConversationId: String?,
        displayName: String? = nil,
        avatarURL: String? = nil,
        bio: String? = nil,
        profileUpdatedAt: Date? = nil,
        blockedAt: Date? = nil
    ) {
        self.inboxId = inboxId
        self.addedAt = addedAt
        self.addedViaConversationId = addedViaConversationId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.bio = bio
        self.profileUpdatedAt = profileUpdatedAt
        self.blockedAt = blockedAt
    }
}

extension DBContact {
    func with(
        displayName: String?,
        avatarURL: String?,
        bio: String?,
        profileUpdatedAt: Date?
    ) -> DBContact {
        DBContact(
            inboxId: inboxId,
            addedAt: addedAt,
            addedViaConversationId: addedViaConversationId,
            displayName: displayName,
            avatarURL: avatarURL,
            bio: bio,
            profileUpdatedAt: profileUpdatedAt,
            blockedAt: blockedAt
        )
    }

    func with(blockedAt: Date?) -> DBContact {
        DBContact(
            inboxId: inboxId,
            addedAt: addedAt,
            addedViaConversationId: addedViaConversationId,
            displayName: displayName,
            avatarURL: avatarURL,
            bio: bio,
            profileUpdatedAt: profileUpdatedAt,
            blockedAt: blockedAt
        )
    }
}
