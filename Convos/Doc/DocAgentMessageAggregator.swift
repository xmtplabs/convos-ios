import Combine
import ConvosCore
import Foundation

struct DocMessagePosition: Comparable {
    let date: Date
    let messageId: String

    init(message: AnyMessage) {
        self.date = message.date
        self.messageId = message.id
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.date == rhs.date { return lhs.messageId < rhs.messageId }
        return lhs.date < rhs.date
    }

    func isNewer(than other: Self?) -> Bool {
        guard let other else { return true }
        return self > other
    }
}

/// Folds every conversation containing one agent inbox into a single ordered
/// message stream for Doc's inbound protocol. Sending remains owned by the
/// explicitly selected agent-DM lane.
@MainActor
final class DocAgentMessageAggregator {
    typealias RepositoryProvider = (String) -> any MessagesRepositoryProtocol

    private let conversationsPublisher: AnyPublisher<[Conversation], Never>
    private let repositoryProvider: RepositoryProvider
    private var conversationsCancellable: AnyCancellable?
    private var messageCancellables: [String: AnyCancellable] = [:]
    private var messageRepositories: [String: any MessagesRepositoryProtocol] = [:]
    private var messagesByConversationId: [String: [AnyMessage]] = [:]
    private var activeConversationIds: Set<String> = []
    private var receivedConversationIds: Set<String> = []
    private var onMessages: (([AnyMessage]) -> Void)?

    init(
        conversationsPublisher: AnyPublisher<[Conversation], Never>,
        repositoryProvider: @escaping RepositoryProvider
    ) {
        self.conversationsPublisher = conversationsPublisher
        self.repositoryProvider = repositoryProvider
    }

    var repositories: [any MessagesRepositoryProtocol] {
        Array(messageRepositories.values)
    }

    func start(
        agentInboxId: String,
        onMessages: @escaping ([AnyMessage]) -> Void
    ) {
        stop()
        self.onMessages = onMessages
        conversationsCancellable = conversationsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conversations in
                self?.updateConversations(conversations, agentInboxId: agentInboxId)
            }
    }

    func stop() {
        conversationsCancellable = nil
        messageCancellables.removeAll()
        messageRepositories.removeAll()
        messagesByConversationId.removeAll()
        activeConversationIds.removeAll()
        receivedConversationIds.removeAll()
        onMessages = nil
    }

    private func updateConversations(
        _ conversations: [Conversation],
        agentInboxId: String
    ) {
        let matchingIds = Set(
            conversations
                .filter { conversation in
                    !conversation.isDraft && conversation.members.contains { member in
                        member.profile.inboxId == agentInboxId
                    }
                }
                .map(\.id)
        )

        for conversationId in activeConversationIds.subtracting(matchingIds) {
            messageCancellables[conversationId] = nil
            messageRepositories[conversationId] = nil
            messagesByConversationId[conversationId] = nil
            receivedConversationIds.remove(conversationId)
        }

        activeConversationIds = matchingIds
        for conversationId in matchingIds where messageCancellables[conversationId] == nil {
            let repository = repositoryProvider(conversationId)
            messageRepositories[conversationId] = repository
            messageCancellables[conversationId] = repository
                .messagesPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] messages in
                    self?.updateMessages(messages, conversationId: conversationId)
                }
        }
        emitIfReady()
    }

    private func updateMessages(
        _ messages: [AnyMessage],
        conversationId: String
    ) {
        guard activeConversationIds.contains(conversationId) else { return }
        messagesByConversationId[conversationId] = messages
        receivedConversationIds.insert(conversationId)
        emitIfReady()
    }

    private func emitIfReady() {
        guard !activeConversationIds.isEmpty,
              activeConversationIds.isSubset(of: receivedConversationIds) else {
            return
        }
        let messages = activeConversationIds
            .flatMap { messagesByConversationId[$0] ?? [] }
            .sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.id < rhs.id }
                return lhs.date < rhs.date
            }
        onMessages?(messages)
    }
}
