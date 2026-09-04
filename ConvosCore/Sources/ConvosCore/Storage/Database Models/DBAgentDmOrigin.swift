import Foundation
import GRDB

/// The parent ("origin") conversation an agent DM was created from.
///
/// An agent DM is its own 2-member conversation, but it is only viewable as a
/// page inside its parent group's conversation view. Routing a DM notification
/// tap therefore needs to map the DM's own conversation id back to that parent
/// group. The link is written to the DM's XMTP custom metadata
/// (`AgentDmInfo.originConversationID`) but that is not readable synchronously
/// or before the XMTP client is ready, so it is mirrored here on every save
/// (extraction) and at creation (`markAsAgentDm`). Kept in its own table rather
/// than a `conversation` column so it never has to thread through
/// `DBConversation`'s builders.
struct DBAgentDmOrigin: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName: String = "agent_dm_origin"

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let originConversationId: Column = Column(CodingKeys.originConversationId)
    }

    /// The agent DM's own conversation id (primary key).
    let conversationId: String
    /// The parent group conversation the DM was created from.
    let originConversationId: String
}

extension DBAgentDmOrigin {
    /// The parent group id for an agent DM, or nil when unknown (a DM saved
    /// before this mapping existed, or a non-DM conversation).
    static func originConversationId(for conversationId: String, in db: Database) throws -> String? {
        try fetchOne(db, key: conversationId)?.originConversationId
    }

    /// The reverse mapping: the agent DM a given agent owns under a given
    /// origin group, or nil when no such DM is known locally. Verifies the
    /// candidate is still classified as an agent DM and that the agent is a
    /// member, so a stale link never routes an event into the wrong
    /// conversation.
    static func dmConversationId(
        forOrigin originConversationId: String,
        agentInboxId: String,
        in db: Database
    ) throws -> String? {
        let links = try DBAgentDmOrigin
            .filter(Columns.originConversationId == originConversationId)
            .fetchAll(db)
        for link in links {
            guard let conversation = try DBConversation.fetchOne(db, key: link.conversationId),
                  conversation.isAgentDm else { continue }
            let isMember = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == link.conversationId)
                .filter(DBConversationMember.Columns.inboxId == agentInboxId)
                .fetchCount(db) > 0
            if isMember { return link.conversationId }
        }
        return nil
    }

    /// Records (or replaces) the DM -> parent link. No-op when `originConversationId`
    /// is nil or empty so a marker written without an origin never clears a good one.
    static func record(conversationId: String, originConversationId: String?, in db: Database) throws {
        guard let originConversationId, !originConversationId.isEmpty else { return }
        try DBAgentDmOrigin(conversationId: conversationId, originConversationId: originConversationId)
            .save(db, onConflict: .replace)
    }
}
