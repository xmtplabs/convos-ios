import Combine
import ConvosMetrics
import Foundation

public final class UserPropertiesBuilder: @unchecked Sendable {
    private let contactsRepository: any ContactsRepositoryProtocol
    private let conversationsRepository: any ConversationsRepositoryProtocol

    public init(
        contactsRepository: any ContactsRepositoryProtocol,
        conversationsRepository: any ConversationsRepositoryProtocol
    ) {
        self.contactsRepository = contactsRepository
        self.conversationsRepository = conversationsRepository
    }

    public func publisher() -> AnyPublisher<UserProperties, Never> {
        contactsRepository.contactsPublisher
            .combineLatest(conversationsRepository.conversationsPublisher)
            .map { contacts, conversations in
                Self.makeProperties(contacts: contacts, conversations: conversations)
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    private static func makeProperties(
        contacts: [Contact],
        conversations: [Conversation]
    ) -> UserProperties {
        let now: Date = Date()
        let cutoff24h: Date = now.addingTimeInterval(-24 * 60 * 60)
        let cutoff7d: Date = now.addingTimeInterval(-7 * 24 * 60 * 60)

        let agentConversations: [Conversation] = conversations.filter { conversation in
            conversation.members.contains(where: \.isAgent)
        }
        let lastAgentMessageDate: Date? = agentConversations
            .compactMap { $0.lastMessage?.createdAt }
            .max()

        let conversationCount24Hours: Int = conversations
            .filter { ($0.lastMessage?.createdAt ?? .distantPast) > cutoff24h }
            .count
        let conversationCount7Days: Int = conversations
            .filter { ($0.lastMessage?.createdAt ?? .distantPast) > cutoff7d }
            .count

        let maxActiveConvoAge: Float = conversations
            .map { Float(now.timeIntervalSince($0.createdAt)) }
            .max() ?? 0

        return UserProperties(
            hasMessagedAssistant: lastAgentMessageDate != nil,
            lastAssistantMessageTimestamp: lastAgentMessageDate?.formatted(.iso8601),
            contactCount: contacts.count,
            conversationCount: conversations.count,
            assistantConversationCount: agentConversations.count,
            conversationCount24Hours: conversationCount24Hours,
            conversationCount7Days: conversationCount7Days,
            maxActiveConvoAge: maxActiveConvoAge
        )
    }
}
