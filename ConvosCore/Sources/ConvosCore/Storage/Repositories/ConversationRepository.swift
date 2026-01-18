import Combine
import Foundation
import GRDB

public protocol ConversationRepositoryProtocol {
    var conversationId: String { get }
    var conversationPublisher: AnyPublisher<Conversation?, Never> { get }
    var myProfileRepository: any MyProfileRepositoryProtocol { get }

    func fetchConversation() throws -> Conversation?
}

enum ConversationRepositoryError: Error {
    case failedFetchingConversation
}

/// Repository for fetching and observing a single conversation
///
/// Provides read-only access to conversation data with reactive updates via Combine.
/// Aggregates conversation details, members, and metadata from the database.
class ConversationRepository: ConversationRepositoryProtocol {
    private let dbReader: any DatabaseReader
    let conversationId: String
    private let messagesRepository: MessagesRepository
    let myProfileRepository: any MyProfileRepositoryProtocol

    init(conversationId: String,
         dbReader: any DatabaseReader,
         inboxStateManager: any InboxStateManagerProtocol) {
        self.dbReader = dbReader
        self.conversationId = conversationId
        self.messagesRepository = MessagesRepository(
            dbReader: dbReader,
            conversationId: conversationId
        )
        self.myProfileRepository = MyProfileRepository(
            inboxStateManager: inboxStateManager,
            databaseReader: dbReader,
            conversationId: conversationId
        )
    }

    lazy var conversationPublisher: AnyPublisher<Conversation?, Never> = {
        let conversationId = conversationId
        return ValueObservation
            .tracking { db in
                try db.composeConversation(for: conversationId)
            }
            .publisher(in: dbReader)
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }()

    func fetchConversation() throws -> Conversation? {
        try dbReader.read { [weak self] db in
            guard let self else { return nil }
            return try db.composeConversation(for: conversationId)
        }
    }
}

fileprivate extension Database {
    func composeConversation(for conversationId: String) throws -> Conversation? {
        guard let dbConversation = try DBConversation
            .filter(DBConversation.Columns.id == conversationId)
            .detailedConversationQuery()
            .fetchOne(self) else {
            return nil
        }

        return dbConversation.hydrateConversation()
    }
}
