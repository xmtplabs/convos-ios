import Combine
import Foundation
import GRDB

public protocol DraftConversationRepositoryProtocol: ConversationRepositoryProtocol {
    var messagesRepository: any MessagesRepositoryProtocol { get }
}

class DraftConversationRepository: DraftConversationRepositoryProtocol {
    private let dbReader: any DatabaseReader
    let conversationId: String
    private let conversationIdPublisher: AnyPublisher<String, Never>
    let messagesRepository: any MessagesRepositoryProtocol
    let myProfileRepository: any MyProfileRepositoryProtocol

    init(dbReader: any DatabaseReader,
         conversationId: String,
         conversationIdPublisher: AnyPublisher<String, Never>,
         inboxStateManager: any InboxStateManagerProtocol) {
        self.dbReader = dbReader
        self.conversationId = conversationId
        self.conversationIdPublisher = conversationIdPublisher
        Log.debug("Initializing DraftConversationRepository with conversationId: \(conversationId)")
        messagesRepository = MessagesRepository(
            dbReader: dbReader,
            conversationId: conversationId,
            conversationIdPublisher: conversationIdPublisher
        )
        myProfileRepository = MyProfileRepository(
            inboxStateManager: inboxStateManager,
            databaseReader: dbReader,
            conversationId: conversationId,
            conversationIdPublisher: conversationIdPublisher
        )
    }

    lazy var conversationPublisher: AnyPublisher<Conversation?, Never> = {
        let dbReader = dbReader
        Log.debug("Creating conversationPublisher for conversationId: \(conversationId)")
        return conversationIdPublisher
            .removeDuplicates()
            .flatMap { conversationId -> AnyPublisher<Conversation?, Never> in
                Log.debug("Conversation ID changed to: \(conversationId)")
                return ValueObservation
                    .tracking { db in
                        do {
                            Log.debug("Tracking conversation \(conversationId)")

                            let conversation = try db.composeConversation(for: conversationId)
                            if conversation != nil {
                                Log.debug(
                                    "Composed conversation: \(conversationId) with kind: \(conversation?.kind ?? .dm)"
                                )
                            } else {
                                Log.debug("No conversation found for ID: \(conversationId)")
                            }
                            return conversation
                        } catch {
                            Log.error("Error composing conversation for ID \(conversationId): \(error)")
                            return nil
                        }
                    }
                    .publisher(in: dbReader)
                    .replaceError(with: nil)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }()

    func fetchConversation() throws -> Conversation? {
        Log.debug("Fetching conversation for ID: \(conversationId)")
        do {
            let conversation: Conversation? = try dbReader.read { [weak self] db in
                guard let self else {
                    Log.warning("DraftConversationRepository deallocated during fetchConversation")
                    return nil
                }
                return try db.composeConversation(for: self.conversationId)
            }
            if conversation != nil {
                Log.debug("Successfully fetched conversation: \(conversationId)")
            } else {
                Log.debug("No conversation found for ID: \(conversationId)")
            }
            return conversation
        } catch {
            Log.error("Error fetching conversation for ID \(conversationId): \(error)")
            throw error
        }
    }
}

fileprivate extension Database {
    func composeConversation(for conversationId: String) throws -> Conversation? {
        do {
            guard let dbConversation = try DBConversation
                .filter(
                    (DBConversation.isDraft(id: conversationId) ?
                     DBConversation.Columns.clientConversationId == conversationId :
                        DBConversation.Columns.id == conversationId)
                )
                .detailedConversationQuery()
                .fetchOne(self) else {
                return nil
            }

            let conversation = dbConversation.hydrateConversation()
            Log.debug("Successfully hydrated conversation: \(conversationId)")
            return conversation
        } catch {
            Log.error("Error composing conversation for ID \(conversationId): \(error)")
            throw error
        }
    }
}
