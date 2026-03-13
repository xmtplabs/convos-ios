import Combine
import ConvosCore
import Foundation

/// A wrapper around MessagesRepository that transforms messages into display items for SwiftUI
@MainActor
protocol MessagesListRepositoryProtocol {
    var messagesListPublisher: AnyPublisher<[MessagesListItemType], Never> { get }
    var conversationMessagesListPublisher: AnyPublisher<(String, [MessagesListItemType]), Never> { get }

    func startObserving()
    func fetchInitial() throws -> [MessagesListItemType]
    func fetchPrevious() throws

    var hasMoreMessages: Bool { get }
    var sendReadReceipts: Bool { get set }
}

@MainActor
final class MessagesListRepository: MessagesListRepositoryProtocol {
    // MARK: - Private Properties

    private let messagesRepository: any MessagesRepositoryProtocol
    private let messagesListSubject: CurrentValueSubject<[MessagesListItemType], Never> = .init([])
    private var cancellables: Set<AnyCancellable> = .init()
    private var dismissCancellable: AnyCancellable?
    private var lastRawMessages: [AnyMessage] = []

    // MARK: - Public Properties

    var messagesListPublisher: AnyPublisher<[MessagesListItemType], Never> {
        messagesListSubject.eraseToAnyPublisher()
    }

    var conversationMessagesListPublisher: AnyPublisher<(String, [MessagesListItemType]), Never> {
        messagesRepository.conversationMessagesResultPublisher
            .map { [weak self] result in
                let processedMessages = self?.processMessages(result.messages, readReceipts: result.readReceipts, memberProfiles: result.memberProfiles) ?? []
                return (result.conversationId, processedMessages)
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
        messagesRepository.conversationMessagesResultPublisher
            .map { [weak self] result in
                self?.processMessages(result.messages, readReceipts: result.readReceipts, memberProfiles: result.memberProfiles) ?? []
            }
            .sink { [weak self] processedMessages in
                self?.messagesListSubject.send(processedMessages)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Methods

    func fetchInitial() throws -> [MessagesListItemType] {
        let result = try messagesRepository.fetchInitialResult()
        return processMessages(result.messages, readReceipts: result.readReceipts, memberProfiles: result.memberProfiles)
    }

    func fetchPrevious() throws {
        // Trigger fetch - results will be delivered through the publisher
        try messagesRepository.fetchPrevious()
    }

    var hasMoreMessages: Bool {
        return messagesRepository.hasMoreMessages
    }

    // MARK: - Private Methods

    private var lastReadReceipts: [ReadReceiptEntry] = []
    private var lastMemberProfiles: [String: MemberProfileInfo] = [:]
    var sendReadReceipts: Bool = true

    private func processMessages(_ messages: [AnyMessage], readReceipts: [ReadReceiptEntry] = [], memberProfiles: [String: MemberProfileInfo] = [:]) -> [MessagesListItemType] {
        lastRawMessages = messages
        lastReadReceipts = readReceipts
        lastMemberProfiles = memberProfiles
        let currentUserInboxIds = Set(messages.filter { $0.base.sender.isCurrentUser }.map { $0.base.sender.profile.inboxId })
        let otherMemberCount = memberProfiles.keys.filter { !currentUserInboxIds.contains($0) }.count
        let items = MessagesListProcessor.process(messages, readReceipts: readReceipts, memberProfiles: memberProfiles, currentOtherMemberCount: otherMemberCount, sendReadReceipts: sendReadReceipts)
        scheduleAssistantJoinDismissIfNeeded(items)
        return items
    }

    private func scheduleAssistantJoinDismissIfNeeded(_ items: [MessagesListItemType]) {
        dismissCancellable?.cancel()
        dismissCancellable = nil

        guard let remaining = items.lazy.compactMap({ item -> TimeInterval? in
            guard case .assistantJoinStatus(let status, _, let date) = item else { return nil }
            let value = status.displayDuration - Date().timeIntervalSince(date)
            return value > 0 ? value : nil
        }).min() else { return }

        dismissCancellable = Just(())
            .delay(for: .seconds(remaining), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let reprocessed = MessagesListProcessor.process(
                    self.lastRawMessages,
                    readReceipts: self.lastReadReceipts,
                    memberProfiles: self.lastMemberProfiles,
                    sendReadReceipts: self.sendReadReceipts
                )
                self.scheduleAssistantJoinDismissIfNeeded(reprocessed)
                self.messagesListSubject.send(reprocessed)
            }
    }
}
