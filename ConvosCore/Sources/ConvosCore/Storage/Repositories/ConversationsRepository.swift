import Combine
import Foundation
import GRDB

/// Where a tapped agent-DM notification should route. A DM is its own
/// conversation but is only viewable as a page inside its parent group, so a
/// tap opens `originConversationId` and selects the DM page for `agentInboxId`.
public struct AgentDmTapRouting: Equatable, Sendable {
    public let originConversationId: String
    public let agentInboxId: String

    public init(originConversationId: String, agentInboxId: String) {
        self.originConversationId = originConversationId
        self.agentInboxId = agentInboxId
    }
}

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

    /// Routing for a tapped agent-DM notification. The tap carries the DM's own
    /// conversation id; return the parent group to open and the agent whose DM
    /// page to select. nil when the id is not a routable agent DM (not a DM, no
    /// recorded parent, or no agent member found).
    func agentDmTapRouting(forConversationId conversationId: String) throws -> AgentDmTapRouting?

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

    func agentDmTapRouting(forConversationId conversationId: String) throws -> AgentDmTapRouting? {
        try dbReader.read { db in
            guard let conversation = try DBConversation.fetchOne(db, key: conversationId),
                  conversation.isAgentDm else {
                return nil
            }
            guard let originConversationId = try DBAgentDmOrigin
                .originConversationId(for: conversationId, in: db) else {
                return nil
            }
            guard let agentInboxId = try Self.verifiedAgentInboxId(
                conversationId: conversationId,
                in: db
            ) else {
                return nil
            }
            return AgentDmTapRouting(
                originConversationId: originConversationId,
                agentInboxId: agentInboxId
            )
        }
    }

    /// The verified-agent member of a 2-member agent DM (the other member is the
    /// current user). Drives which pager page a DM tap selects.
    private static func verifiedAgentInboxId(conversationId: String, in db: Database) throws -> String? {
        let memberInboxIds = try DBConversationMember
            .filter(DBConversationMember.Columns.conversationId == conversationId)
            .fetchAll(db)
            .map(\.inboxId)
        guard !memberInboxIds.isEmpty else { return nil }
        return try DBProfile
            .fetchAll(db, inboxIds: memberInboxIds)
            .first { $0.agentVerification.isVerified }?
            .inboxId
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
        let conversations = try dbConversationDetails.composeConversations(from: self)
        // Fold each group's separate agent DM into its row so the list can
        // render a combined preview and a DM-aware unread indicator.
        let summaries = try agentDmSummaries(forGroupIds: conversations.map(\.id), consent: consent)
        let folded = try conversations.map { (conversation: Conversation) -> Conversation in
            guard let summary = try summaries[conversation.id]
                ?? agentDmSummaryFromGroupMembers(of: conversation, consent: consent) else {
                return conversation
            }
            var row = conversation
            row.agentDm = summary
            return row
        }
        // The SQL order only knows each group's own messages; a reply in the
        // folded DM lane must float the origin conversation just like a group
        // message would. Re-sort in memory by the newer of the two lanes,
        // keeping the SQL order for ties so rows without a DM are unaffected.
        guard folded.contains(where: { $0.agentDm != nil }) else { return folded }
        return folded
            .enumerated()
            .sorted { (lhs: EnumeratedSequence<[Conversation]>.Element, rhs: EnumeratedSequence<[Conversation]>.Element) -> Bool in
                let lhsDate: Date = lhs.element.lastActivityDate
                let rhsDate: Date = rhs.element.lastActivityDate
                guard lhsDate == rhsDate else { return lhsDate > rhsDate }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The folded agent DM for each of `groupIds`, keyed by the group's id.
    ///
    /// Resolved through `agent_dm_origin`, the link the DM records about itself
    /// at creation and re-records on every save. The group's own member list is
    /// deliberately not consulted: it is rewritten wholesale by member sync, and
    /// a group whose agent member row is missing still has a perfectly good DM
    /// carrying the messages this preview is made of. Deriving the link from the
    /// group's members made the row's preview track the volatility of those rows
    /// rather than the existence of the DM, so it came and went.
    ///
    /// Two queries for the whole list rather than a lookup per group, run in
    /// this same transaction so ValueObservation tracks the DMs and keeps the
    /// list reactive.
    func agentDmSummaries(
        forGroupIds groupIds: [String],
        consent: [Consent]
    ) throws -> [String: Conversation.AgentDmSummary] {
        guard !groupIds.isEmpty else { return [:] }
        let links = try DBAgentDmOrigin
            .filter(groupIds.contains(DBAgentDmOrigin.Columns.originConversationId))
            .fetchAll(self)
        guard !links.isEmpty else { return [:] }

        let dmIds: [String] = links.map(\.conversationId)
        let dmDetails = try DBConversation
            .filter(dmIds.contains(DBConversation.Columns.id))
            .filter(DBConversation.Columns.isAgentDm == true)
            .filter(consent.contains(DBConversation.Columns.consent))
            .filter(DBConversation.Columns.expiresAt == nil || DBConversation.Columns.expiresAt > Date())
            .filter(DBConversation.Columns.isUnused == false)
            .joining(required: DBConversation.localState.filter(ConversationLocalState.Columns.wasRemoved == false))
            .detailedConversationQuery()
            .fetchAll(self)
        guard !dmDetails.isEmpty else { return [:] }

        let currentInboxId = try DBInbox.currentInboxId(self) ?? ""
        let contactNameResolver = try ContactsRepository.contactNameResolverInTransaction(db: self)
        var dmsById: [String: Conversation] = [:]
        for details in dmDetails {
            let dm = details.hydrateConversation(
                currentInboxId: currentInboxId,
                contactNameResolver: contactNameResolver
            )
            dmsById[dm.id] = dm
        }

        var summaries: [String: Conversation.AgentDmSummary] = [:]
        for link in links {
            guard let dm = dmsById[link.conversationId],
                  let summary = dm.agentDmSummary else {
                continue
            }
            // A group is normally the origin of exactly one DM. If it somehow
            // owns more, the most recently active one wins, matching how the
            // row sorts.
            if let existing = summaries[link.originConversationId],
               (existing.lastMessage?.createdAt ?? .distantPast) >= (summary.lastMessage?.createdAt ?? .distantPast) {
                continue
            }
            summaries[link.originConversationId] = summary
        }
        return summaries
    }

    /// Legacy path for a DM saved before `agent_dm_origin` existed, which has no
    /// link row until its next save. Finds the DM from the group's verified-agent
    /// member instead, which is what every row used to do.
    func agentDmSummaryFromGroupMembers(
        of conversation: Conversation,
        consent: [Consent]
    ) throws -> Conversation.AgentDmSummary? {
        guard let agentMember = conversation.members.first(where: { $0.isVerifiedAgent }) else {
            return nil
        }
        guard let dm = try composeOneToOne(
            with: agentMember.profile.inboxId,
            excluding: nil,
            consent: consent,
            onlyAgentDms: true
        ) else {
            return nil
        }
        return Conversation.AgentDmSummary(
            inboxId: agentMember.profile.inboxId,
            displayName: agentMember.displayName,
            lastMessage: dm.lastMessage,
            isUnread: dm.isUnread
        )
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

fileprivate extension Conversation {
    /// The row's most recent activity across both lanes: the group's own last
    /// message (falling back to `createdAt`, matching the SQL ordering key)
    /// and the folded agent DM's last message.
    var lastActivityDate: Date {
        let groupDate: Date = lastMessage?.createdAt ?? createdAt
        guard let dmDate = agentDm?.lastMessage?.createdAt else { return groupDate }
        return max(groupDate, dmDate)
    }

    /// This agent DM rendered as the summary its origin group's row carries.
    /// The agent is the DM's other member, so the name comes from the DM's own
    /// membership rather than the group's.
    var agentDmSummary: AgentDmSummary? {
        guard let agent = members.first(where: { !$0.isCurrentUser }) else { return nil }
        return AgentDmSummary(
            inboxId: agent.profile.inboxId,
            displayName: agent.displayName,
            lastMessage: lastMessage,
            isUnread: isUnread
        )
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
