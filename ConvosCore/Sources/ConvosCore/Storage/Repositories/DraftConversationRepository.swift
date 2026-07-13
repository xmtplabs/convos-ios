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
         sessionStateManager: any SessionStateManagerProtocol) {
        self.dbReader = dbReader
        self.conversationId = conversationId
        self.conversationIdPublisher = conversationIdPublisher
        Log.debug("Initializing DraftConversationRepository with conversationId: \(conversationId)")
        messagesRepository = MessagesRepository(
            dbReader: dbReader,
            conversationId: conversationId,
            currentInboxId: MessagesRepository.currentInboxId(from: dbReader),
            conversationIdPublisher: conversationIdPublisher
        )
        myProfileRepository = MyProfileRepository(
            sessionStateManager: sessionStateManager,
            databaseReader: dbReader,
            conversationId: conversationId,
            conversationIdPublisher: conversationIdPublisher
        )
    }

    // `map` + `switchToLatest` (not `flatMap`, which merges) so that when a
    // join flips the conversation id, the previous id's observation is
    // cancelled. Merged, the stale observation kept re-emitting the old draft
    // row on every overlapping database write during the join, interleaving
    // with the joined conversation's emissions and flickering the chat header
    // and embedded invite card between the two conversations.
    // `removeDuplicates` on the output drops the redundant re-emissions a
    // region-based observation produces for writes that don't change the
    // composed value.
    lazy var conversationPublisher: AnyPublisher<Conversation?, Never> = {
        let dbReader = dbReader
        Log.debug("Creating conversationPublisher for conversationId: \(conversationId)")
        return conversationIdPublisher
            .removeDuplicates()
            .map { conversationId -> AnyPublisher<Conversation?, Never> in
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
            .switchToLatest()
            .removeDuplicates()
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

            let currentInboxId = try DBInbox.currentInboxId(self) ?? ""
            let conversation = dbConversation.hydrateConversation(currentInboxId: currentInboxId)
            Log.debug("Successfully hydrated conversation: \(conversationId)")
            return conversation
        } catch {
            Log.error("Error composing conversation for ID \(conversationId): \(error)")
            throw error
        }
    }
}
