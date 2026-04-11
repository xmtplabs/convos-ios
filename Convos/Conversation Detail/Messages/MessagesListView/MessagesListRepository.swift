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
}

@MainActor
final class MessagesListRepository: MessagesListRepositoryProtocol {
    // MARK: - Private Properties

    private let messagesRepository: any MessagesRepositoryProtocol
    private let transcriptRepository: any VoiceMemoTranscriptRepositoryProtocol
    private let conversationIdSubject: CurrentValueSubject<String, Never>
    /// Returns whether the user has granted on-device speech recognition permission.
    /// Used to suppress the synthetic "Tap to transcribe" affordance once the user
    /// has authorized transcription — from that point forward, voice memos with no
    /// stored transcript row should silently auto-transcribe rather than prompt.
    private let speechPermissionProvider: @MainActor () -> Bool
    private let messagesListSubject: CurrentValueSubject<[MessagesListItemType], Never> = .init([])
    private var cancellables: Set<AnyCancellable> = .init()
    private var dismissCancellable: AnyCancellable?
    private var transcriptCancellable: AnyCancellable?
    private var lastRawMessages: [AnyMessage] = []
    private var storedTranscripts: [String: VoiceMemoTranscript] = [:]
    var currentOtherMemberCount: Int = 0

    // MARK: - Public Properties

    var messagesListPublisher: AnyPublisher<[MessagesListItemType], Never> {
        messagesListSubject.eraseToAnyPublisher()
    }

    var conversationMessagesListPublisher: AnyPublisher<(String, [MessagesListItemType]), Never> {
        messagesRepository.conversationMessagesPublisher
            .map { [weak self] conversationId, messages in
                let processedMessages = self?.processMessages(messages, conversationId: conversationId) ?? []
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
        speechPermissionProvider: @escaping @MainActor () -> Bool = { false }
    ) {
        self.messagesRepository = messagesRepository
        self.transcriptRepository = transcriptRepository
        self.conversationIdSubject = .init(conversationId)
        self.speechPermissionProvider = speechPermissionProvider
    }

    func startObserving() {
        guard !hasStartedObserving else { return }
        hasStartedObserving = true
        messagesRepository.messagesPublisher
            .map { [weak self] messages in
                self?.processMessages(messages, conversationId: self?.conversationIdSubject.value) ?? []
            }
            .sink { [weak self] processedMessages in
                self?.messagesListSubject.send(processedMessages)
            }
            .store(in: &cancellables)

        conversationMessagesListPublisher
            .map(\ .0)
            .removeDuplicates()
            .sink { [weak self] conversationId in
                self?.handleConversationIdChanged(conversationId)
            }
            .store(in: &cancellables)

        observeTranscripts(for: conversationIdSubject.value)
    }

    // MARK: - Public Methods

    func fetchInitial() throws -> [MessagesListItemType] {
        let messages = try messagesRepository.fetchInitial()
        // Seed the stored transcripts synchronously so the very first list
        // emission already carries any persisted transcripts. Otherwise the
        // transcripts publisher subscription in startObserving() lags behind
        // the initial fetch by one run loop, causing transcript rows to
        // "animate in" a moment after the conversation opens.
        storedTranscripts = (try? transcriptRepository.fetchAllTranscripts(in: conversationIdSubject.value)) ?? [:]
        return processMessages(messages, conversationId: conversationIdSubject.value)
    }

    func fetchPrevious() throws {
        // Trigger fetch - results will be delivered through the publisher
        try messagesRepository.fetchPrevious()
    }

    var hasMoreMessages: Bool {
        return messagesRepository.hasMoreMessages
    }

    // MARK: - Private Methods

    private func processMessages(_ messages: [AnyMessage], conversationId: String?) -> [MessagesListItemType] {
        lastRawMessages = messages
        let transcripts = synthesizeTranscriptItems(messages: messages, conversationId: conversationId)
        let items = MessagesListProcessor.process(
            messages,
            otherMemberCount: currentOtherMemberCount,
            voiceMemoTranscripts: transcripts
        )
        scheduleAssistantJoinDismissIfNeeded(items)
        return items
    }

    /// Build the per-message transcript map. Every incoming voice memo with a
    /// stored DB row gets an entry. Voice memos *without* a stored row only get a
    /// synthetic `.notRequested` entry when the user has not yet granted speech
    /// recognition permission — that's the only state where the UI should expose
    /// a "Tap to transcribe" affordance. After permission has been granted the
    /// scheduler auto-enqueues these messages, so the row should stay hidden until
    /// the writer flips it to `.pending`.
    private func synthesizeTranscriptItems(
        messages: [AnyMessage],
        conversationId: String?
    ) -> [String: VoiceMemoTranscriptListItem] {
        let permissionGranted = speechPermissionProvider()
        let effectiveConversationId = conversationId ?? conversationIdSubject.value
        var result: [String: VoiceMemoTranscriptListItem] = [:]
        for message in messages {
            guard let attachment = message.content.primaryVoiceMemoAttachment else { continue }
            // Outgoing voice memos are never transcribed; skip them entirely so the
            // map doesn't carry rows we won't render.
            guard !message.senderIsCurrentUser else { continue }
            let stored = storedTranscripts[message.messageId]
            // Permanently failed transcripts (e.g. on-device speech models are
            // unavailable) are kept in the database so the scheduler does not
            // re-enqueue them, but the UI hides them so the user doesn't see a
            // misleading retry affordance. Nothing to render here.
            if stored?.status == .permanentlyFailed {
                continue
            }
            if stored == nil, permissionGranted {
                // Auto-transcribe path: don't fabricate a row. The scheduler will
                // call markPending shortly and the writer-driven publisher will
                // surface the real `.pending` row when it lands.
                continue
            }
            let item = VoiceMemoTranscriptListItem(
                parentMessageId: message.messageId,
                conversationId: effectiveConversationId,
                attachmentKey: attachment.key,
                mimeType: attachment.mimeType,
                senderDisplayName: message.sender.profile.displayName,
                isOutgoing: false,
                status: stored?.status ?? .notRequested,
                text: stored?.text,
                errorDescription: stored?.errorDescription
            )
            result[message.messageId] = item
        }
        return result
    }

    private func handleConversationIdChanged(_ conversationId: String) {
        guard conversationIdSubject.value != conversationId else { return }
        conversationIdSubject.send(conversationId)
        storedTranscripts = (try? transcriptRepository.fetchAllTranscripts(in: conversationId)) ?? [:]
        observeTranscripts(for: conversationId)
    }

    private func observeTranscripts(for conversationId: String) {
        transcriptCancellable?.cancel()
        transcriptCancellable = transcriptRepository.transcriptsPublisher(in: conversationId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcripts in
                guard let self else { return }
                self.storedTranscripts = transcripts
                let reprocessed = self.processMessages(self.lastRawMessages, conversationId: self.conversationIdSubject.value)
                self.messagesListSubject.send(reprocessed)
            }
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
                let reprocessed = self.processMessages(self.lastRawMessages, conversationId: self.conversationIdSubject.value)
                self.scheduleAssistantJoinDismissIfNeeded(reprocessed)
                self.messagesListSubject.send(reprocessed)
            }
    }
}
