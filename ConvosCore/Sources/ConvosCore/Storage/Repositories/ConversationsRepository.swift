import Combine
import Foundation
import GRDB

public protocol ConversationsRepositoryProtocol {
    var conversationsPublisher: AnyPublisher<[Conversation], Never> { get }
    func fetchAll() throws -> [Conversation]
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
}

extension Array where Element == DBConversationDetails {
    func composeConversations(from database: Database) throws -> [Conversation] {
        let conversations: [Conversation] = self.compactMap { $0.hydrateConversation() }

        let dmConversationIds = conversations.map(\.id)
        guard !dmConversationIds.isEmpty else { return conversations }

        let dmLinks = try DBDMLink
            .filter(dmConversationIds.contains(DBDMLink.Columns.dmConversationId))
            .fetchAll(database)
        guard !dmLinks.isEmpty else { return conversations }

        let originIds = Set(dmLinks.map(\.originConversationId))
        let originConversations = try DBConversation
            .filter(originIds.contains(DBConversation.Columns.id))
            .fetchAll(database)
        let originNames = Dictionary(uniqueKeysWithValues: originConversations.compactMap { c in
            c.name.map { (c.id, $0) }
        })

        let memberInboxIds = Set(dmLinks.map(\.memberInboxId))
        let memberProfiles = try DBMemberProfile
            .filter(memberInboxIds.contains(DBMemberProfile.Columns.inboxId))
            .fetchAll(database)
        let memberNames = Dictionary(memberProfiles.map { ($0.inboxId, $0.name ?? "Somebody") },
                                     uniquingKeysWith: { first, _ in first })

        var linksByDMId: [String: DBDMLink] = [:]
        for link in dmLinks {
            linksByDMId[link.dmConversationId] = link
        }

        return conversations.map { conversation in
            guard let link = linksByDMId[conversation.id] else { return conversation }
            let originName = originNames[link.originConversationId]
            let memberName = memberNames[link.memberInboxId]
            guard originName != nil || memberName != nil else { return conversation }
            return conversation.with(
                dmOriginConversationName: originName,
                dmOriginMemberName: memberName
            )
        }
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
            .detailedConversationQuery()
            .fetchAll(self)
        return try dbConversationDetails.composeConversations(from: self)
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

        let assistantJoinRequest = DBConversation.association(
            to: DBConversation.latestAssistantJoinRequestCTE,
            on: { conversation, cte in
                conversation.id == cte[Column("conversationId")]
            }
        ).forKey("conversationAssistantJoinRequest")

        return self
            .including(optional: DBConversation.invite)
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
            .with(DBConversation.lastMessageWithSourceCTE)
            .including(optional: lastMessageWithSource)
            .with(DBConversation.latestAssistantJoinRequestCTE)
            .including(optional: assistantJoinRequest)
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
