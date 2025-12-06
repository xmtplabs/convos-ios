import Combine
import Foundation

extension Conversation {
    public static func mock(
        id: String = UUID().uuidString,
        clientConversationId: String = UUID().uuidString,
        creator: ConversationMember = .mock(),
        date: Date = Date(),
        consent: Consent = .allowed,
        kind: ConversationKind = .dm,
        name: String = "The Convo",
        description: String = "Where we talk about all things Convos.",
        members: [ConversationMember] = [],
        otherMember: ConversationMember? = .mock(),
        messages: [Message] = [],
        lastMessage: MessagePreview? = nil
    ) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inboxId: UUID().uuidString,
            clientId: UUID().uuidString,
            creator: creator,
            createdAt: Date(),
            consent: consent,
            kind: kind,
            name: name,
            description: description,
            members: members,
            otherMember: otherMember,
            messages: messages,
            isPinned: false,
            isUnread: false,
            isMuted: false,
            lastMessage: lastMessage,
            imageURL: nil,
            isDraft: false,
            invite: .mock(),
            expiresAt: Date(),
            debugInfo: .empty
        )
    }

    public static func empty(id: String = "", clientId: String = "") -> Self {
        .init(
            id: id,
            clientConversationId: id,
            inboxId: "",
            clientId: clientId,
            creator: .empty(isCurrentUser: true),
            createdAt: .distantFuture,
            consent: .allowed,
            kind: .group,
            name: "",
            description: "",
            members: [],
            otherMember: nil,
            messages: [],
            isPinned: false,
            isUnread: false,
            isMuted: false,
            lastMessage: nil,
            imageURL: nil,
            isDraft: true,
            invite: nil,
            expiresAt: Date(),
            debugInfo: .empty
        )
    }
}

extension Invite {
    public static func mock() -> Self {
        .init(
            conversationId: "conversation_123",
            urlSlug: "invite_code_123",
            expiresAt: nil,
            expiresAfterUse: false
        )
    }
}

class MockConversationsRepository: ConversationsRepositoryProtocol {
    private let conversations: [Conversation] = [
        .mock(),
        .mock(),
        .mock(),
        .mock()
    ]

    lazy var conversationsPublisher: AnyPublisher<[Conversation], Never> = {
        Just(conversations).eraseToAnyPublisher()
    }()

    func fetchAll() throws -> [Conversation] {
        conversations
    }
}
