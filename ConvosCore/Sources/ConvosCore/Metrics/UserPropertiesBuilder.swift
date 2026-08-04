import Combine
import ConvosMetrics
import Foundation

public final class UserPropertiesBuilder: @unchecked Sendable {
    private let contactsRepository: any ContactsRepositoryProtocol
    private let conversationsRepository: any ConversationsRepositoryProtocol
    private let accountId: String?
    private let throttleInterval: TimeInterval
    private let throttleQueue: DispatchQueue

    public init(
        contactsRepository: any ContactsRepositoryProtocol,
        conversationsRepository: any ConversationsRepositoryProtocol,
        accountId: String?,
        throttleInterval: TimeInterval = 30,
        throttleQueue: DispatchQueue = .main
    ) {
        self.contactsRepository = contactsRepository
        self.conversationsRepository = conversationsRepository
        self.accountId = accountId
        self.throttleInterval = throttleInterval
        self.throttleQueue = throttleQueue
    }

    /// The upstream repositories re-emit on every database write, which
    /// during sync means several emissions per second. Throttling before the
    /// map keeps the property computation to at most one per interval (the
    /// first value passes through immediately), and deduplication drops
    /// captures whose analytics-visible content did not change, so the
    /// analytics SDK is not hit with a network capture per database write.
    public func publisher() -> AnyPublisher<UserProperties, Never> {
        contactsRepository.contactsPublisher
            .combineLatest(conversationsRepository.conversationsPublisher)
            .throttle(for: .seconds(throttleInterval), scheduler: throttleQueue, latest: true)
            .map { [accountId] contacts, conversations in
                Self.makeProperties(contacts: contacts, conversations: conversations, accountId: accountId)
            }
            .removeDuplicates(by: Self.isEffectivelyEqual)
            .eraseToAnyPublisher()
    }

    /// Equality for deduplication purposes. `maxActiveConvoAge` is derived
    /// from the wall clock at computation time, so it differs on every
    /// recompute and comparing it would defeat deduplication entirely; it
    /// still reaches the analytics backend whenever any other property
    /// changes (and on the first emission of every launch).
    static func isEffectivelyEqual(_ lhs: UserProperties, _ rhs: UserProperties) -> Bool {
        lhs.hasMessagedAssistant == rhs.hasMessagedAssistant &&
            lhs.lastAssistantMessageTimestamp == rhs.lastAssistantMessageTimestamp &&
            lhs.contactCount == rhs.contactCount &&
            lhs.conversationCount == rhs.conversationCount &&
            lhs.assistantConversationCount == rhs.assistantConversationCount &&
            lhs.conversationCount24Hours == rhs.conversationCount24Hours &&
            lhs.conversationCount7Days == rhs.conversationCount7Days
    }

    private static func makeProperties(
        contacts: [Contact],
        conversations: [Conversation],
        accountId: String?
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
            maxActiveConvoAge: maxActiveConvoAge,
            accountId: accountId
        )
    }
}
