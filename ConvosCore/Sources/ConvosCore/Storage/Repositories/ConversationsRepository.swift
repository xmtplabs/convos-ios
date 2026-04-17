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
