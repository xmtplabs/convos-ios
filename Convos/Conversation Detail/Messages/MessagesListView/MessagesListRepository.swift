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

    var currentOtherMemberCount: Int { get set }

    /// Toggles the expanded state for a voice memo transcript row.
    func setTranscriptExpanded(_ expanded: Bool, for messageId: String)
}

@MainActor
final class MessagesListRepository: MessagesListRepositoryProtocol {
    // MARK: - Private Properties

    private let messagesRepository: any MessagesRepositoryProtocol
    private let transcriptRepository: any VoiceMemoTranscriptRepositoryProtocol
    private let conversationId: String
    private let transcriptExpansionStore: VoiceMemoTranscriptExpansionStore
    private let messagesListSubject: CurrentValueSubject<[MessagesListItemType], Never> = .init([])
    private var cancellables: Set<AnyCancellable> = .init()
    private var dismissCancellable: AnyCancellable?
    private var transcriptCancellable: AnyCancellable?
    private var lastRawMessages: [AnyMessage] = []
    private var transcripts: [String: VoiceMemoTranscript] = [:]
    private var expandedTranscriptMessageIds: Set<String> = []
    var currentOtherMemberCount: Int = 0

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

    init(
        messagesRepository: any MessagesRepositoryProtocol,
        transcriptRepository: any VoiceMemoTranscriptRepositoryProtocol,
        conversationId: String,
        transcriptExpansionStore: VoiceMemoTranscriptExpansionStore? = nil
    ) {
        self.messagesRepository = messagesRepository
        self.transcriptRepository = transcriptRepository
        self.conversationId = conversationId
        self.transcriptExpansionStore = transcriptExpansionStore
            ?? VoiceMemoTranscriptExpansionStore(conversationId: conversationId)
        self.expandedTranscriptMessageIds = self.transcriptExpansionStore.loadExpandedMessageIds()
    }

    func setTranscriptExpanded(_ expanded: Bool, for messageId: String) {
        if expanded {
            expandedTranscriptMessageIds.insert(messageId)
        } else {
            expandedTranscriptMessageIds.remove(messageId)
        }
        transcriptExpansionStore.save(expandedTranscriptMessageIds)
        let reprocessed = processMessages(lastRawMessages)
        messagesListSubject.send(reprocessed)
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

        transcriptCancellable = transcriptRepository.transcriptsPublisher(in: conversationId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcripts in
                guard let self else { return }
                self.transcripts = transcripts
                let reprocessed = self.processMessages(self.lastRawMessages)
                self.messagesListSubject.send(reprocessed)
            }
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
        lastRawMessages = messages
        let items = MessagesListProcessor.process(messages, otherMemberCount: currentOtherMemberCount)
        let withTranscripts = injectTranscriptRows(into: items, messages: messages)
        scheduleAssistantJoinDismissIfNeeded(withTranscripts)
        return withTranscripts
    }

    private func injectTranscriptRows(
        into items: [MessagesListItemType],
        messages: [AnyMessage]
    ) -> [MessagesListItemType] {
        guard !transcripts.isEmpty else { return items }

        let messagesById = Dictionary(uniqueKeysWithValues: messages.map { ($0.messageId, $0) })

        var result: [MessagesListItemType] = []
        result.reserveCapacity(items.count)

        for item in items {
            result.append(item)
            guard case .messages(let group) = item else { continue }
            for message in group.messages {
                guard case .attachment(let attachment) = message.content,
                      attachment.mediaType == .audio,
                      let transcript = transcripts[message.messageId] else { continue }
                guard let live = messagesById[message.messageId] else { continue }
                let row = VoiceMemoTranscriptListItem(
                    parentMessageId: message.messageId,
                    conversationId: conversationId,
                    attachmentKey: attachment.key,
                    mimeType: attachment.mimeType,
                    isOutgoing: live.senderIsCurrentUser,
                    status: transcript.status,
                    text: transcript.text,
                    errorDescription: transcript.errorDescription,
                    isExpanded: expandedTranscriptMessageIds.contains(message.messageId)
                )
                result.append(.voiceMemoTranscript(row))
            }
        }

        return result
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
                let reprocessed = MessagesListProcessor.process(self.lastRawMessages, otherMemberCount: self.currentOtherMemberCount)
                self.scheduleAssistantJoinDismissIfNeeded(reprocessed)
                self.messagesListSubject.send(reprocessed)
            }
    }
}
