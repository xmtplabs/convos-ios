import Combine
import ConvosCore
import Foundation

struct DocMessagePosition: Comparable, Hashable {
    let date: Date
    let messageId: String

    init(date: Date, messageId: String) {
        self.date = date
        self.messageId = messageId
    }

    init(message: AnyMessage) {
        self.init(date: message.date, messageId: message.id)
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

enum DocWireDebugLog {
    static func sentinelReceived(_ message: AnyMessage, expectedSenderId: String) {
        #if DEBUG
        guard case .text(let text) = message.content,
              DocStateMessage.isDataPlaneText(text) else {
            return
        }
        Log.info(
            "Doc wire sentinel received message=\(message.id) " +
                "senderMatches=\(message.senderId == expectedSenderId)"
        )
        #endif
    }

    static func decodeFailed(text: String, messageId: String) {
        #if DEBUG
        guard DocStateMessage.isDataPlaneText(text) else { return }
        Log.warning("Doc wire sentinel failed to decode message=\(messageId)")
        #endif
    }

    static func snapshotPersisted(docCount: Int, itemCount: Int, contentCount: Int) {
        #if DEBUG
        Log.info(
            "Doc wire snapshot persisted docs=\(docCount) " +
                "items=\(itemCount) contents=\(contentCount)"
        )
        #endif
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
    private var liveMessagesByConversationId: [String: [AnyMessage]] = [:]
    private var backfillMessagesByConversationId: [String: [AnyMessage]] = [:]
    private var conversationsWithBackfilledState: Set<String> = []
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
#if DEBUG
        Log.info("Doc wire aggregator started for agent \(agentInboxId)")
#endif
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
        liveMessagesByConversationId.removeAll()
        backfillMessagesByConversationId.removeAll()
        conversationsWithBackfilledState.removeAll()
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

#if DEBUG
        let laneIds = matchingIds.sorted().joined(separator: ",")
        Log.info("Doc wire lanes updated count=\(matchingIds.count) ids=\(laneIds)")
#endif

        for conversationId in activeConversationIds.subtracting(matchingIds) {
            messageCancellables[conversationId] = nil
            messageRepositories[conversationId] = nil
            liveMessagesByConversationId[conversationId] = nil
            backfillMessagesByConversationId[conversationId] = nil
            conversationsWithBackfilledState.remove(conversationId)
            receivedConversationIds.remove(conversationId)
        }

        activeConversationIds = matchingIds
        for conversationId in matchingIds where messageCancellables[conversationId] == nil {
            let repository = repositoryProvider(conversationId)
            messageRepositories[conversationId] = repository
            refreshBackfill(
                repository: repository,
                conversationId: conversationId,
                agentInboxId: agentInboxId
            )
            messageCancellables[conversationId] = repository
                .messagesPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] messages in
                    self?.updateMessages(
                        messages,
                        conversationId: conversationId,
                        agentInboxId: agentInboxId
                    )
                }
        }
        emitIfReady()
    }

    private func updateMessages(
        _ messages: [AnyMessage],
        conversationId: String,
        agentInboxId: String
    ) {
        guard activeConversationIds.contains(conversationId) else { return }
        liveMessagesByConversationId[conversationId] = messages
        receivedConversationIds.insert(conversationId)
        if !conversationsWithBackfilledState.contains(conversationId),
           let repository = messageRepositories[conversationId] {
            refreshBackfill(
                repository: repository,
                conversationId: conversationId,
                agentInboxId: agentInboxId
            )
        }
#if DEBUG
        let sentinelCount = messages.reduce(into: 0) { count, message in
            guard case .text(let text) = message.content,
                  DocStateMessage.isDataPlaneText(text) else {
                return
            }
            count += 1
        }
        Log.info(
            "Doc wire lane receipt id=\(conversationId) messages=\(messages.count) " +
                "sentinels=\(sentinelCount)"
        )
#endif
        emitIfReady()
    }

    private func refreshBackfill(
        repository: any MessagesRepositoryProtocol,
        conversationId: String,
        agentInboxId: String
    ) {
        do {
            let recentMessages = try repository.fetchRecent(limit: Constant.historyBackfillLimit)
            let result = Self.wireBackfill(
                from: recentMessages,
                agentInboxId: agentInboxId
            )
            backfillMessagesByConversationId[conversationId] = result.messages
            receivedConversationIds.insert(conversationId)
            if result.foundState {
                conversationsWithBackfilledState.insert(conversationId)
            }
#if DEBUG
            Log.info(
                "Doc wire history backfill id=\(conversationId) scanned=\(recentMessages.count) " +
                    "sentinels=\(result.messages.count) stateFound=\(result.foundState)"
            )
#endif
        } catch {
            Log.warning("Doc wire history backfill failed id=\(conversationId): \(error.localizedDescription)")
        }
    }

    private static func wireBackfill(
        from messages: [AnyMessage],
        agentInboxId: String
    ) -> (messages: [AnyMessage], foundState: Bool) {
        let wireMessages = messages
            .filter { message in
                guard message.senderId == agentInboxId,
                      case .text(let text) = message.content else {
                    return false
                }
                return DocStateMessage.isDataPlaneText(text)
            }
            .sorted { DocMessagePosition(message: $0) > DocMessagePosition(message: $1) }
        let controlMessages = wireMessages.filter(isControlMessage)
        guard let stateMessage = wireMessages.first(where: isStateMessage) else {
            return (wireMessages, false)
        }
        let statePosition = DocMessagePosition(message: stateMessage)
        let editorialMessagesSinceState = wireMessages.filter { message in
            !isControlMessage(message) && DocMessagePosition(message: message) >= statePosition
        }
        let backfill = Dictionary(
            (controlMessages + editorialMessagesSinceState).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return (
            backfill.values.sorted {
                DocMessagePosition(message: $0) > DocMessagePosition(message: $1)
            },
            true
        )
    }

    private static func isStateMessage(_ message: AnyMessage) -> Bool {
        guard case .text(let text) = message.content,
              case .state = DocStateMessage.parseEvent(text) else {
            return false
        }
        return true
    }

    private static func isControlMessage(_ message: AnyMessage) -> Bool {
        guard case .text(let text) = message.content else { return false }
        return DocControlMessage.parseEvent(text) != nil
    }

    private func emitIfReady() {
        guard !activeConversationIds.isEmpty,
              activeConversationIds.isSubset(of: receivedConversationIds) else {
            return
        }
        var messagesById: [String: AnyMessage] = [:]
        for conversationId in activeConversationIds {
            let messages = (backfillMessagesByConversationId[conversationId] ?? []) +
                (liveMessagesByConversationId[conversationId] ?? [])
            for message in messages {
                messagesById[message.id] = message
            }
        }
        let messages = messagesById.values
            .sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.id < rhs.id }
                return lhs.date < rhs.date
            }
#if DEBUG
        let sentinelCount = messages.reduce(into: 0) { count, message in
            guard case .text(let text) = message.content,
                  DocStateMessage.isDataPlaneText(text) else {
                return
            }
            count += 1
        }
        Log.info(
            "Doc wire aggregate emitted lanes=\(activeConversationIds.count) " +
                "messages=\(messages.count) sentinels=\(sentinelCount)"
        )
#endif
        onMessages?(messages)
    }

    private enum Constant {
        static let historyBackfillLimit: Int = 500
    }
}
