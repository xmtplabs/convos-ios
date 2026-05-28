import Combine
import Foundation
import GRDB

public protocol ConversationsRepositoryProtocol {
    var conversationsPublisher: AnyPublisher<[Conversation], Never> { get }
    func fetchAll() throws -> [Conversation]
    /// Returns the most-recently-active conversation that consists of
    /// exactly the current user and the supplied inbox - i.e. the
    /// existing 1:1 to route "Chat" taps from a contact card into so
    /// the app doesn't let the user spin up a second redundant 1:1
    /// with the same person. `excluding`, when non-nil, skips that
    /// conversation in the search - the caller passes the
    /// currently-open conversation's id so tapping "Chat" while
    /// already in a 1:1 with this person falls through to the picker
    /// (the user clearly wants to start a different chat). Honours
    /// the repo's `consent` scope and the same draft / expired /
    /// quarantined / unused exclusions as `fetchAll`. Returns nil
    /// when no other match exists.
    func findOneToOne(with inboxId: String, excluding excludedConversationId: String?) throws -> Conversation?
}

final class ConversationsRepository: ConversationsRepositoryProtocol {
    private let dbReader: any DatabaseReader
    private let consent: [Consent]

    let conversationsPublisher: AnyPublisher<[Conversation], Never>

    init(dbReader: any DatabaseReader, consent: [Consent]) {
        self.dbReader = dbReader
        self.consent = consent
        self.conversationsPublisher = ValueObservation
            .tracking { db in
                do {
                    return try db.composeAllConversations(consent: consent)
                } catch {
                    Log.error("Error composing all conversations: \(error)")
                    throw error
                }
            }
            .publisher(in: dbReader)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    func fetchAll() throws -> [Conversation] {
        try dbReader.read { [weak self] db in
            guard let self else { return [] }
            return try db.composeAllConversations(consent: consent)
        }
    }

    func findOneToOne(with inboxId: String, excluding excludedConversationId: String?) throws -> Conversation? {
        try dbReader.read { [consent] db in
            try db.composeOneToOne(
                with: inboxId,
                excluding: excludedConversationId,
                consent: consent
            )
        }
    }
}

extension Array where Element == DBConversationDetails {
    func composeConversations(from database: Database) throws -> [Conversation] {
        // Empty string when no inbox is authorized yet — hydration treats
        // that as "no member is current user".
        let currentInboxId = try DBInbox.fetchAll(database).first?.inboxId ?? ""
        let dbConversations: [DBConversationDetails] = self

        let conversations: [Conversation] = dbConversations
            .compactMap { dbConversationDetails in
            dbConversationDetails.hydrateConversation(currentInboxId: currentInboxId)
        }

        return conversations
    }
}

fileprivate extension Database {
    func composeAllConversations(consent: [Consent]) throws -> [Conversation] {
        let dbConversationDetails = try DBConversation
            .filter(
                !DBConversation.Columns.id.like("draft-%")
                || (DBConversation.Columns.inviteTag != nil
                    && length(DBConversation.Columns.inviteTag) > 0)
            )
            .filter(consent.contains(DBConversation.Columns.consent))
            .filter(DBConversation.Columns.expiresAt == nil || DBConversation.Columns.expiresAt > Date())
            .filter(DBConversation.Columns.isUnused == false)
            // Exclude held / quarantined inbound conversations from the main
            // feed. Released rows (sender promoted to contact) keep their
            // `quarantinedAt` for audit but expose `quarantineReleasedAt` —
            // those reappear here.
            .filter(
                DBConversation.Columns.quarantinedAt == nil
                || DBConversation.Columns.quarantineReleasedAt != nil
            )
            .detailedConversationQuery()
            .fetchAll(self)
        return try dbConversationDetails.composeConversations(from: self)
    }

    func composeOneToOne(
        with otherInboxId: String,
        excluding excludedConversationId: String?,
        consent: [Consent]
    ) throws -> Conversation? {
        // SQL-pushed predicate so we don't hydrate every conversation
        // the user has just to find the 1:1 with one specific inbox.
        // We require the other inbox to be a member and the total
        // member count to be 2 - the existing rule that the local DB
        // only carries conversations the current user is a member of
        // means that pair is self + other. `detailedConversationQuery`
        // orders by COALESCE(lastMessageDate, createdAt) DESC, so the
        // first row is the most-recently-active match. The optional
        // `excluding` is the source-conversation id when "Chat" was
        // tapped from inside a 1:1 with the same person - skipping
        // that row lets the user fall through to the picker to start
        // a fresh chat.
        let oneToOnePredicate: SQL = """
            EXISTS (
                SELECT 1 FROM conversation_members AS cm_other
                WHERE cm_other.conversationId = conversation.id
                AND cm_other.inboxId = \(otherInboxId)
            )
            AND EXISTS (
                SELECT 1 FROM conversation_members AS cm_self
                WHERE cm_self.conversationId = conversation.id
                AND cm_self.inboxId IN (SELECT inboxId FROM inbox)
            )
            AND (
                SELECT COUNT(*) FROM conversation_members AS cm_count
                WHERE cm_count.conversationId = conversation.id
            ) = 2
            """
        var request = DBConversation
            .filter(
                !DBConversation.Columns.id.like("draft-%")
                || (DBConversation.Columns.inviteTag != nil
                    && length(DBConversation.Columns.inviteTag) > 0)
            )
            .filter(consent.contains(DBConversation.Columns.consent))
            .filter(DBConversation.Columns.expiresAt == nil || DBConversation.Columns.expiresAt > Date())
            .filter(DBConversation.Columns.isUnused == false)
            .filter(
                DBConversation.Columns.quarantinedAt == nil
                || DBConversation.Columns.quarantineReleasedAt != nil
            )
            .filter(literal: oneToOnePredicate)
        if let excludedConversationId {
            request = request.filter(DBConversation.Columns.id != excludedConversationId)
        }
        let dbConversationDetails = try request
            .detailedConversationQuery()
            .fetchOne(self)
        guard let details = dbConversationDetails else { return nil }
        let currentInboxId = try DBInbox.fetchAll(self).first?.inboxId ?? ""
        return details.hydrateConversation(currentInboxId: currentInboxId)
    }
}

extension QueryInterfaceRequest where RowDecoder == DBConversation {
    func detailedConversationQuery() -> QueryInterfaceRequest<DBConversationDetails> {
        let lastMessageWithSource = DBConversation.association(
            to: DBConversation.lastMessageWithSourceCTE,
            on: { conversation, cte in
                conversation.id == cte[Column("conversationId")]
            }
        ).forKey("conversationLastMessageWithSource")

        let agentJoinRequest = DBConversation.association(
            to: DBConversation.latestAgentJoinRequestCTE,
            on: { conversation, cte in
                conversation.id == cte[Column("conversationId")]
            }
        ).forKey("conversationAgentJoinRequest")

        return self
            .including(all: DBConversation.invites)
            .including(
                required: DBConversation.creator
                    .forKey("conversationCreator")
                    .select([
                        DBConversationMember.Columns.role,
                        DBConversationMember.Columns.createdAt,
                    ])
                    .including(required: DBConversationMember.memberProfile)
                    .including(optional: DBConversationMember.inviterProfile)
            )
            .including(required: DBConversation.localState)
            .including(optional: DBConversation.agentBuilderSummary)
            .with(DBConversation.lastMessageWithSourceCTE)
            .including(optional: lastMessageWithSource)
            .with(DBConversation.latestAgentJoinRequestCTE)
            .including(optional: agentJoinRequest)
            .including(
                all: DBConversation._members
                    .forKey("conversationMembers")
                    .select([
                        DBConversationMember.Columns.role,
                        DBConversationMember.Columns.createdAt,
                    ])
                    .including(required: DBConversationMember.memberProfile)
                    .including(optional: DBConversationMember.inviterProfile)
            )
            .group(DBConversation.Columns.id)
            .order(sql: "COALESCE(conversationLastMessageWithSource.date, conversation.createdAt) DESC")
            .asRequest(of: DBConversationDetails.self)
    }
}
