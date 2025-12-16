import Foundation
import GRDB

// MARK: - ConversationLocalState

struct ConversationLocalState: Codable, FetchableRecord, PersistableRecord, Hashable {
    static var databaseTableName: String = "conversationLocalState"

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let isPinned: Column = Column(CodingKeys.isPinned)
        static let isUnread: Column = Column(CodingKeys.isUnread)
        static let isUnreadUpdatedAt: Column = Column(CodingKeys.isUnreadUpdatedAt)
        static let isMuted: Column = Column(CodingKeys.isMuted)
    }

    let conversationId: String
    let isPinned: Bool
    let isUnread: Bool
    let isUnreadUpdatedAt: Date
    let isMuted: Bool

    static let conversationForeignKey: ForeignKey = ForeignKey([Columns.conversationId], to: [DBConversation.Columns.id])

    static let conversation: BelongsToAssociation<ConversationLocalState, DBConversation> = belongsTo(
        DBConversation.self,
        using: conversationForeignKey
    )
}

extension ConversationLocalState {
    func with(isUnread: Bool) -> Self {
        .init(
            conversationId: conversationId,
            isPinned: isPinned,
            isUnread: isUnread,
            isUnreadUpdatedAt: !isUnread ? Date() : (isUnread != self.isUnread ? Date() : isUnreadUpdatedAt),
            isMuted: isMuted
        )
    }
    func with(isPinned: Bool) -> Self {
        .init(
            conversationId: conversationId,
            isPinned: isPinned,
            isUnread: isUnread,
            isUnreadUpdatedAt: isUnreadUpdatedAt,
            isMuted: isMuted
        )
    }
    func with(isMuted: Bool) -> Self {
        .init(
            conversationId: conversationId,
            isPinned: isPinned,
            isUnread: isUnread,
            isUnreadUpdatedAt: isUnreadUpdatedAt,
            isMuted: isMuted
        )
    }
}
