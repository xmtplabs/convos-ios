import Foundation
import GRDB

// MARK: - ConversationLocalState

struct ConversationLocalState: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "conversationLocalState"

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let isPinned: Column = Column(CodingKeys.isPinned)
        static let isUnread: Column = Column(CodingKeys.isUnread)
        static let isUnreadUpdatedAt: Column = Column(CodingKeys.isUnreadUpdatedAt)
        static let isMuted: Column = Column(CodingKeys.isMuted)
        static let pinnedOrder: Column = Column(CodingKeys.pinnedOrder)
        static let hidesInviteCard: Column = Column(CodingKeys.hidesInviteCard)
        static let leftHostedInviteSession: Column = Column(CodingKeys.leftHostedInviteSession)
        static let wasRemoved: Column = Column(CodingKeys.wasRemoved)
    }

    let conversationId: String
    let isPinned: Bool
    let isUnread: Bool
    let isUnreadUpdatedAt: Date
    let isMuted: Bool
    let pinnedOrder: Int?
    let hidesInviteCard: Bool
    let leftHostedInviteSession: Bool
    let wasRemoved: Bool

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
            isMuted: isMuted,
            pinnedOrder: pinnedOrder,
            hidesInviteCard: hidesInviteCard,
            leftHostedInviteSession: leftHostedInviteSession,
            wasRemoved: wasRemoved
        )
    }
    func with(isPinned: Bool) -> Self {
        .init(
            conversationId: conversationId,
            isPinned: isPinned,
            isUnread: isUnread,
            isUnreadUpdatedAt: isUnreadUpdatedAt,
            isMuted: isMuted,
            pinnedOrder: pinnedOrder,
            hidesInviteCard: hidesInviteCard,
            leftHostedInviteSession: leftHostedInviteSession,
            wasRemoved: wasRemoved
        )
    }
    func with(isMuted: Bool) -> Self {
        .init(
            conversationId: conversationId,
            isPinned: isPinned,
            isUnread: isUnread,
            isUnreadUpdatedAt: isUnreadUpdatedAt,
            isMuted: isMuted,
            pinnedOrder: pinnedOrder,
            hidesInviteCard: hidesInviteCard,
            leftHostedInviteSession: leftHostedInviteSession,
            wasRemoved: wasRemoved
        )
    }
    func with(pinnedOrder: Int?) -> Self {
        .init(
            conversationId: conversationId,
            isPinned: isPinned,
            isUnread: isUnread,
            isUnreadUpdatedAt: isUnreadUpdatedAt,
            isMuted: isMuted,
            pinnedOrder: pinnedOrder,
            hidesInviteCard: hidesInviteCard,
            leftHostedInviteSession: leftHostedInviteSession,
            wasRemoved: wasRemoved
        )
    }
    func with(hidesInviteCard: Bool) -> Self {
        .init(
            conversationId: conversationId,
            isPinned: isPinned,
            isUnread: isUnread,
            isUnreadUpdatedAt: isUnreadUpdatedAt,
            isMuted: isMuted,
            pinnedOrder: pinnedOrder,
            hidesInviteCard: hidesInviteCard,
            leftHostedInviteSession: leftHostedInviteSession,
            wasRemoved: wasRemoved
        )
    }
    func with(leftHostedInviteSession: Bool) -> Self {
        .init(
            conversationId: conversationId,
            isPinned: isPinned,
            isUnread: isUnread,
            isUnreadUpdatedAt: isUnreadUpdatedAt,
            isMuted: isMuted,
            pinnedOrder: pinnedOrder,
            hidesInviteCard: hidesInviteCard,
            leftHostedInviteSession: leftHostedInviteSession,
            wasRemoved: wasRemoved
        )
    }
    func with(wasRemoved: Bool) -> Self {
        .init(
            conversationId: conversationId,
            isPinned: isPinned,
            isUnread: isUnread,
            isUnreadUpdatedAt: isUnreadUpdatedAt,
            isMuted: isMuted,
            pinnedOrder: pinnedOrder,
            hidesInviteCard: hidesInviteCard,
            leftHostedInviteSession: leftHostedInviteSession,
            wasRemoved: wasRemoved
        )
    }
}
