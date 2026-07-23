import Combine
import Foundation
import GRDB

public protocol ConversationsRepositoryProtocol {
    var conversationsPublisher: AnyPublisher<[Conversation], Never> { get }
    func fetchAll() throws -> [Conversation]
    /// Async variant of `fetchAll()`. Runs the read on GRDB's reader pool
    /// instead of blocking the calling thread, so main-actor callers can
    /// prime the conversations list without hanging the main thread.
    func fetchAll() async throws -> [Conversation]
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
    /// unused exclusions as `fetchAll`. Returns nil when no other
    /// match exists.
    func findOneToOne(with inboxId: String, excluding excludedConversationId: String?) throws -> Conversation?

    /// The user's agent DM with this inbox, if one exists (conversations
    /// carrying the agent-DM marker only).
    func findAgentDm(with inboxId: String) throws -> Conversation?

    /// Conversations that contain an agent provisioned from `templateId`,
    /// split by who added that agent: `addedByCurrentUser` when the agent
    /// member's `invitedBy` is one of the current user's inboxes, otherwise
    /// `addedByOthers`. Backs the agent contact card's "Convos with you" and
    /// "someone else added them" sections. Emits the current partition
    /// immediately and a fresh one whenever the underlying database changes,
    /// so the sections stay live while the card is on screen. Honours the
    /// repo's `consent` scope and the same draft / expired / unused
    /// exclusions as `fetchAll`.
    func conversationsPublisher(withAgentTemplateId templateId: String) -> AnyPublisher<AgentTemplateConversations, Never>
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

    func fetchAll() async throws -> [Conversation] {
        try await dbReader.read { [consent] db in
            try db.composeAllConversations(consent: consent)
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

    /// The user's DM with this agent, if one exists. Unlike `findOneToOne`
    /// this only matches conversations carrying the agent-DM marker, so an
    /// ordinary 2-member conversation with the agent (e.g. the builder
    /// conversation the agent was made in) never shadows the DM.
    func findAgentDm(with inboxId: String) throws -> Conversation? {
        try dbReader.read { [consent] db in
            try db.composeOneToOne(
                with: inboxId,
                excluding: nil,
                consent: consent,
                onlyAgentDms: true
            )
        }
    }

    func conversationsPublisher(withAgentTemplateId templateId: String) -> AnyPublisher<AgentTemplateConversations, Never> {
        ValueObservation
            .tracking { [consent] db in
                do {
                    return try db.composeAgentTemplateConversations(templateId: templateId, consent: consent)
                } catch {
                    Log.error("Error composing agent template conversations: \(error)")
                    throw error
                }
            }
            // The tracked region spans every conversation table, so without
            // this an unrelated write would re-emit an identical partition.
            .removeDuplicates()
            .publisher(in: dbReader)
            .replaceError(with: .empty)
            .eraseToAnyPublisher()
    }
}

extension Array where Element == DBConversationDetails {
    func composeConversations(from database: Database) throws -> [Conversation] {
        // Empty string when no inbox is authorized yet — hydration treats
        // that as "no member is current user".
        let currentInboxId = try DBInbox.currentInboxId(database) ?? ""
        // Fallback contact name for the last-message preview when a member's
        // per-conversation name is empty. Fetching here also registers this
        // observation on the `contact` table, so a contact rename refreshes the
        // list previews.
        let contactNameResolver = try ContactsRepository.contactNameResolverInTransaction(db: database)
        let dbConversations: [DBConversationDetails] = self

        let conversations: [Conversation] = dbConversations
            .compactMap { dbConversationDetails in
            dbConversationDetails.hydrateConversation(
                currentInboxId: currentInboxId,
                contactNameResolver: contactNameResolver
            )
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
            // Agent DMs render as a page inside their origin conversation,
            // never as their own row in the conversations list.
            .filter(DBConversation.Columns.isAgentDm == false)
            .joining(required: DBConversation.localState.filter(ConversationLocalState.Columns.wasRemoved == false))
            .detailedConversationQuery()
            .fetchAll(self)
        return try dbConversationDetails.composeConversations(from: self)
    }

    func composeAgentTemplateConversations(templateId: String, consent: [Consent]) throws -> AgentTemplateConversations {
        // Filter and partition in Swift over the hydrated conversations:
        // `member.profile.agentTemplateId` is the trusted accessor over the
        // profile metadata, and `invitedBy` already carries the agent's
        // inviter, so this avoids a brittle SQL JSON_EXTRACT predicate.
        // Trade-off: this hydrates every allowed conversation and partitions
        // in memory rather than filtering in SQL - fine at expected
        // conversation counts; revisit with a SQL predicate if it gets hot.
        let currentInboxIds = Set(try DBInbox.fetchAll(self).map(\.inboxId))
        let conversations = try composeAllConversations(consent: consent)
        var addedByCurrentUser: [Conversation] = []
        var addedByOthers: [Conversation] = []
        for conversation in conversations {
            let agentMember = conversation.members.first { member in
                member.isAgent && member.profile.agentTemplateId == templateId
            }
            guard let agentMember else { continue }
            if let inviterInboxId = agentMember.invitedBy?.inboxId, currentInboxIds.contains(inviterInboxId) {
                addedByCurrentUser.append(conversation)
            } else {
                addedByOthers.append(conversation)
            }
        }
        return AgentTemplateConversations(
            addedByCurrentUser: addedByCurrentUser,
            addedByOthers: addedByOthers
        )
    }

    func composeOneToOne(
        with otherInboxId: String,
        excluding excludedConversationId: String?,
        consent: [Consent],
        onlyAgentDms: Bool = false
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
            .joining(required: DBConversation.localState.filter(ConversationLocalState.Columns.wasRemoved == false))
            .filter(literal: oneToOnePredicate)
        if let excludedConversationId {
            request = request.filter(DBConversation.Columns.id != excludedConversationId)
        }
        if onlyAgentDms {
            request = request.filter(DBConversation.Columns.isAgentDm == true)
        } else {
            // Plain 1:1 lookups must never resolve to an agent DM (it renders
            // inside its origin conversation, not as a standalone chat).
            request = request.filter(DBConversation.Columns.isAgentDm == false)
        }
        let dbConversationDetails = try request
            .detailedConversationQuery()
            .fetchOne(self)
        guard let details = dbConversationDetails else { return nil }
        let currentInboxId = try DBInbox.currentInboxId(self) ?? ""
        let contactNameResolver = try ContactsRepository.contactNameResolverInTransaction(db: self)
        return details.hydrateConversation(currentInboxId: currentInboxId, contactNameResolver: contactNameResolver)
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
            // Optional join: a creator who left the group has no
            // conversation_members row anymore, and a required join would
            // silently drop the conversation from every list and detail
            // query on the remaining members' devices. The nested profile
            // joins must also be optional -- GRDB cannot chain a required
            // association behind an optional one.
            .including(
                optional: DBConversation.creator
                    .forKey("conversationCreator")
                    .select([
                        DBConversationMember.Columns.conversationId,
                        DBConversationMember.Columns.inboxId,
                        DBConversationMember.Columns.role,
                        DBConversationMember.Columns.createdAt,
                    ])
                    .including(optional: DBConversationMember.profile)
                    .including(optional: DBConversationMember.avatarSlot)
                    .including(optional: DBConversationMember.inviterProfileIdentity)
                    .including(optional: DBConversationMember.myProfileIdentity)
                    .including(optional: DBConversationMember.inviterMyProfileIdentity)
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
                        DBConversationMember.Columns.conversationId,
                        DBConversationMember.Columns.inboxId,
                        DBConversationMember.Columns.role,
                        DBConversationMember.Columns.createdAt,
                    ])
                    .including(optional: DBConversationMember.profile)
                    .including(optional: DBConversationMember.avatarSlot)
                    .including(optional: DBConversationMember.inviterProfileIdentity)
                    .including(optional: DBConversationMember.myProfileIdentity)
                    .including(optional: DBConversationMember.inviterMyProfileIdentity)
            )
            .group(DBConversation.Columns.id)
            .order(sql: "COALESCE(conversationLastMessageWithSource.date, conversation.createdAt) DESC")
            .asRequest(of: DBConversationDetails.self)
    }
}
