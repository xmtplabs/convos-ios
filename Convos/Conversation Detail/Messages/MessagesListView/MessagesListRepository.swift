import Combine
import ConvosCore
import Foundation

/// A wrapper around MessagesRepository that transforms messages into display items for SwiftUI
@MainActor
protocol MessagesListRepositoryProtocol {
    var messagesListPublisher: AnyPublisher<[MessagesListItemType], Never> { get }
    var conversationMessagesListPublisher: AnyPublisher<(String, [MessagesListItemType]), Never> { get }

    func startObserving()

    /// Fetches the initial page of messages (most recent messages)
    func fetchInitial() throws -> [MessagesListItemType]

    /// Fetches previous (older) messages
    /// Results are delivered through the messagesListPublisher
    func fetchPrevious() throws

    /// Indicates if there are more messages to load
    var hasMoreMessages: Bool { get }
}

@MainActor
final class MessagesListRepository: MessagesListRepositoryProtocol {
    // MARK: - Private Properties

    private let messagesRepository: any MessagesRepositoryProtocol
    private let messagesListSubject: CurrentValueSubject<[MessagesListItemType], Never> = .init([])
    private var cancellables: Set<AnyCancellable> = .init()

    // MARK: - Public Properties

    var messagesListPublisher: AnyPublisher<[MessagesListItemType], Never> {
        messagesListSubject.eraseToAnyPublisher()
    }

    var conversationMessagesListPublisher: AnyPublisher<(String, [MessagesListItemType]), Never> {
        messagesRepository.conversationMessagesPublisher
            .map { [weak self] conversationId, messages in
                let processedMessages = self?.processMessages(messages) ?? []
                return (conversationId, processedMessages)
            }
            .handleEvents(receiveOutput: { [weak self] _, processedMessages in
                self?.messagesListSubject.send(processedMessages)
            })
            .eraseToAnyPublisher()
    }

    // MARK: - Initialization

    private var hasStartedObserving: Bool = false

    init(messagesRepository: any MessagesRepositoryProtocol) {
        self.messagesRepository = messagesRepository
    }

    func startObserving() {
        guard !hasStartedObserving else { return }
        hasStartedObserving = true
        messagesRepository.messagesPublisher
            .map { [weak self] messages in
                self?.processMessages(messages) ?? []
            }
            .sink { [weak self] processedMessages in
                self?.messagesListSubject.send(processedMessages)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Methods

    func fetchInitial() throws -> [MessagesListItemType] {
        let messages = try messagesRepository.fetchInitial()
        return processMessages(messages)
    }

    func fetchPrevious() throws {
        // Trigger fetch - results will be delivered through the publisher
        try messagesRepository.fetchPrevious()
    }

    var hasMoreMessages: Bool {
        return messagesRepository.hasMoreMessages
    }

    // MARK: - Private Methods

    private func processMessages(_ messages: [AnyMessage]) -> [MessagesListItemType] {
        return MessagesListProcessor.process(messages)
    }
}
