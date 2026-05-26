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

    var currentOtherMemberCount: Int { get set }
    var sendReadReceipts: Bool { get set }
    /// The verified Convos agent in the conversation, if any. When set,
    /// the processor attaches an `AgentContactCardInfo` to the agent's
    /// first messages group (or synthesizes an empty one) and suppresses the
    /// legacy "Agent joined" update bubble.
    var verifiedAgent: ConversationMember? { get set }
    /// The persisted Agent Builder summary for this conversation, if any.
    /// When set, the processor prepends a `.agentBuilderSummary` cell and
    /// filters every messages-group whose timestamp predates `cutoffDate`.
    var agentBuilderSummary: AgentBuilderSummary? { get set }
    /// `true` while the conversation is rendered under the agent builder
    /// UI (set by `AgentBuilderView.onAppear`, cleared on disappear). The
    /// processor uses this to suppress the legacy "Agent joined" update
    /// row throughout the builder flow — pre-Make it lives under the builder
    /// overlay anyway, and post-Make the contact card is the canonical
    /// arrival signal so the row would just compete with the morph.
    var isInAgentBuilderFlow: Bool { get set }
}

@MainActor
final class MessagesListRepository: MessagesListRepositoryProtocol {
    // MARK: - Private Properties

    private let messagesRepository: any MessagesRepositoryProtocol
    private let transcriptRepository: any VoiceMemoTranscriptRepositoryProtocol
    private let conversationId: String
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
    var verifiedAgent: ConversationMember? {
        didSet {
            guard oldValue != verifiedAgent else { return }
            reprocessCachedMessages()
        }
    }
    var agentBuilderSummary: AgentBuilderSummary? {
        didSet {
            guard oldValue != agentBuilderSummary else { return }
            reprocessCachedMessages()
        }
    }
    var isInAgentBuilderFlow: Bool = false {
        didSet {
            guard oldValue != isInAgentBuilderFlow else { return }
            reprocessCachedMessages()
        }
    }

    /// Re-run the processor against the cached raw messages and emit so the
    /// view layer picks up freshly-set `verifiedAgent` /
    /// `agentBuilderSummary` without waiting for the next message delivery.
    /// Intentionally does NOT short-circuit on `lastRawMessages.isEmpty` —
    /// `MessagesListProcessor.process` synthesizes an agent contact card
    /// group when `verifiedAgent` is set, even with zero messages, and we
    /// need that synthesized output to reach the view.
    private func reprocessCachedMessages() {
        let reprocessed = processMessages(
            lastRawMessages,
            readReceipts: lastReadReceipts,
            memberProfiles: lastMemberProfiles
        )
        messagesListSubject.send(reprocessed)
    }

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

    init(
        messagesRepository: any MessagesRepositoryProtocol,
        transcriptRepository: any VoiceMemoTranscriptRepositoryProtocol,
        conversationId: String,
        speechPermissionProvider: @escaping @MainActor () -> Bool = { false }
    ) {
        self.messagesRepository = messagesRepository
        self.transcriptRepository = transcriptRepository
        self.conversationId = conversationId
        self.speechPermissionProvider = speechPermissionProvider
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

        transcriptCancellable = transcriptRepository.transcriptsPublisher(in: conversationId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcripts in
                guard let self else { return }
                self.storedTranscripts = transcripts
                let reprocessed = self.processMessages(
                    self.lastRawMessages,
                    readReceipts: self.lastReadReceipts,
                    memberProfiles: self.lastMemberProfiles
                )
                self.messagesListSubject.send(reprocessed)
            }
    }

    // MARK: - Public Methods

    func fetchInitial() throws -> [MessagesListItemType] {
        let result = try messagesRepository.fetchInitialResult()
        // Seed the stored transcripts synchronously so the very first list
        // emission already carries any persisted transcripts. Otherwise the
        // transcripts publisher subscription in startObserving() lags behind
        // the initial fetch by one run loop, causing transcript rows to
        // "animate in" a moment after the conversation opens.
        storedTranscripts = (try? transcriptRepository.fetchAllTranscripts(in: conversationId)) ?? [:]
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
    private var lastOtherMemberCount: Int = 0
    private var lastReadByMembers: [ConversationMember] = []
    var sendReadReceipts: Bool = true

    private func processMessages(_ messages: [AnyMessage], readReceipts: [ReadReceiptEntry] = [], memberProfiles: [String: MemberProfileInfo] = [:]) -> [MessagesListItemType] {
        lastRawMessages = messages
        lastReadReceipts = readReceipts
        lastMemberProfiles = memberProfiles
        lastOtherMemberCount = currentOtherMemberCount
        let transcripts = synthesizeTranscriptItems(messages: messages)
        let items = MessagesListProcessor.process(
            messages,
            voiceMemoTranscripts: transcripts,
            readReceipts: readReceipts,
            memberProfiles: memberProfiles,
            currentOtherMemberCount: currentOtherMemberCount,
            sendReadReceipts: sendReadReceipts,
            previousReadByMembers: lastReadByMembers,
            verifiedAgent: verifiedAgent,
            agentBuilderSummary: agentBuilderSummary,
            isInAgentBuilderFlow: isInAgentBuilderFlow
        )
        lastReadByMembers = Self.extractReadByMembers(from: items)
        scheduleAgentJoinDismissIfNeeded(items)
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
        messages: [AnyMessage]
    ) -> [String: VoiceMemoTranscriptListItem] {
        let permissionGranted = speechPermissionProvider()
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
                conversationId: conversationId,
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

    private static func extractReadByMembers(from items: [MessagesListItemType]) -> [ConversationMember] {
        for item in items.reversed() {
            if case .messages(let group) = item, group.isLastGroupSentByCurrentUser {
                return group.readByMembers
            }
        }
        return []
    }

    private func scheduleAgentJoinDismissIfNeeded(_ items: [MessagesListItemType]) {
        dismissCancellable?.cancel()
        dismissCancellable = nil

        guard let remaining = items.lazy.compactMap({ item -> TimeInterval? in
            guard case .agentJoinStatus(let status, _, let date) = item else { return nil }
            let value = status.displayDuration - Date().timeIntervalSince(date)
            return value > 0 ? value : nil
        }).min() else { return }

        dismissCancellable = Just(())
            .delay(for: .seconds(remaining), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let reprocessed = self.processMessages(self.lastRawMessages, readReceipts: self.lastReadReceipts, memberProfiles: self.lastMemberProfiles)
                self.scheduleAgentJoinDismissIfNeeded(reprocessed)
                self.messagesListSubject.send(reprocessed)
            }
    }
}
