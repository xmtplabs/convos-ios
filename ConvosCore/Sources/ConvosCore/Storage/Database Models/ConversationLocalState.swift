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
        static let hasHadOtherMembers: Column = Column(CodingKeys.hasHadOtherMembers)
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
    /// Set-once high-water mark: true once the conversation has ever had a
    /// member besides the local inbox. Current membership rows are deleted
    /// when a member leaves, so this is the only queryable record of a
    /// joined-then-departed member. Local-only, so network sync can never
    /// clobber it; deleted with the conversation. Read by
    /// `ConversationEngagement.isEngaged`.
    let hasHadOtherMembers: Bool

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
            wasRemoved: wasRemoved,
            hasHadOtherMembers: hasHadOtherMembers
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
            wasRemoved: wasRemoved,
            hasHadOtherMembers: hasHadOtherMembers
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
            wasRemoved: wasRemoved,
            hasHadOtherMembers: hasHadOtherMembers
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
            wasRemoved: wasRemoved,
            hasHadOtherMembers: hasHadOtherMembers
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
            wasRemoved: wasRemoved,
            hasHadOtherMembers: hasHadOtherMembers
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
            wasRemoved: wasRemoved,
            hasHadOtherMembers: hasHadOtherMembers
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
            wasRemoved: wasRemoved,
            hasHadOtherMembers: hasHadOtherMembers
        )
    }
    func with(hasHadOtherMembers: Bool) -> Self {
        .init(
            conversationId: conversationId,
            isPinned: isPinned,
            isUnread: isUnread,
            isUnreadUpdatedAt: isUnreadUpdatedAt,
            isMuted: isMuted,
            pinnedOrder: pinnedOrder,
            hidesInviteCard: hidesInviteCard,
            leftHostedInviteSession: leftHostedInviteSession,
            wasRemoved: wasRemoved,
            hasHadOtherMembers: hasHadOtherMembers
        )
    }
}
