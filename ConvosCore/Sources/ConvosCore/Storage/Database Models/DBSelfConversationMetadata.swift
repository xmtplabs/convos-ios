import Foundation
import GRDB

/// The current user's conversation-scoped `ProfileUpdate` metadata, keyed by
/// `(inboxId, conversationId)`. Some metadata keys are per-conversation on the
/// wire - cloud connection grants carry the grants for one conversation only,
/// and the agent timezone is published only to agent conversations - so they
/// cannot live in the global `DBMyProfile.metadata` map: a global map makes
/// one conversation's grants overwrite another's and broadcasts them to every
/// conversation the user touches.
///
/// At send time the publisher merges this row's map over the global self
/// metadata (scoped keys win), so every `ProfileUpdate` a conversation receives
/// carries both the user's global identity metadata and that conversation's
/// scoped keys.
struct DBSelfConversationMetadata: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    static let databaseTableName: String = "selfConversationMetadata"

    enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let metadata: Column = Column(CodingKeys.metadata)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let inboxId: String
    let conversationId: String
    var metadata: ProfileMetadata
    var updatedAt: Date
}
