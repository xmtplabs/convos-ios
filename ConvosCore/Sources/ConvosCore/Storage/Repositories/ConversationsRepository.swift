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
        let dbConversations: [DBConversationDetails] = self

        let conversations: [Conversation] = dbConversations
            .compactMap { dbConversationDetails in
            dbConversationDetails.hydrateConversation()
        }

        return conversations
    }
}

fileprivate extension Database {
    func composeAllConversations(consent: [Consent]) throws -> [Conversation] {
        let dbConversationDetails = try DBConversation
            .filter(!DBConversation.Columns.id.like("draft-%"))
            .filter(consent.contains(DBConversation.Columns.consent))
            .filter(DBConversation.Columns.expiresAt == nil || DBConversation.Columns.expiresAt > Date())
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

        return self
            .including(optional: DBConversation.invite)
            .including(
                required: DBConversation.creator
                    .forKey("conversationCreator")
                    .select([DBConversationMember.Columns.role])
                    .including(required: DBConversationMember.memberProfile)
            )
            .including(required: DBConversation.localState)
            .with(DBConversation.lastMessageWithSourceCTE)
            .including(optional: lastMessageWithSource)
            .including(
                all: DBConversation._members
                    .forKey("conversationMembers")
                    .select([DBConversationMember.Columns.role])
                    .including(required: DBConversationMember.memberProfile)
            )
            .group(DBConversation.Columns.id)
            // Sort by last message date if available, otherwise by conversation createdAt
            .order(sql: "COALESCE(conversationLastMessageWithSource.date, conversation.createdAt) DESC")
            .asRequest(of: DBConversationDetails.self)
    }
}
