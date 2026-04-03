import Foundation
import GRDB

public protocol UnreadConversationsCountRepositoryProtocol: Sendable {
    func fetchUnreadCount() throws -> Int
}

public final class UnreadConversationsCountRepository: UnreadConversationsCountRepositoryProtocol, @unchecked Sendable {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func fetchUnreadCount() throws -> Int {
        try databaseReader.read { db in
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.isUnread == true)
                .joining(
                    required: ConversationLocalState.conversation
                        .filter(!DBConversation.Columns.id.like("draft-%"))
                        .filter([Consent.allowed].contains(DBConversation.Columns.consent))
                )
                .fetchCount(db)
        }
    }
}
