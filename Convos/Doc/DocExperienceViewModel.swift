import Combine
import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import ConvosMetrics
import Foundation

enum DocPreviewStage: String {
    case welcome
    case connect
    case empty
    case cards
    case forYou
    case share
    case disconnected
    case roomUnbound
    case roomBound
    case docSheet

    static var current: DocPreviewStage? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-DocPreviewState"),
              arguments.indices.contains(flagIndex + 1) else {
            return nil
        }
        return DocPreviewStage(rawValue: arguments[flagIndex + 1])
    }
}

enum DocItemSendState: Hashable {
    case resolving(answer: DocAnswer, clientMessageId: String)
    case awaitingDelivery(answer: DocAnswer, clientMessageId: String)
    case failed(answer: DocAnswer)
}

enum DocContentLoadState: Hashable {
    case idle
    case loading
    case failed
}

@MainActor @Observable
final class DocExperienceViewModel {
    private(set) var conversationViewModel: NewConversationViewModel?
    private(set) var agentDmSession: AgentDmSession?
    private(set) var state: DocState?
    private(set) var pendingItems: [DocWaitingItem] = []
    private(set) var docContentsById: [String: DocContent] = [:]
    private(set) var docContentLoadStates: [String: DocContentLoadState] = [:]
    private(set) var itemSendStates: [String: DocItemSendState] = [:]
    private(set) var pendingScreenshotCount: Int = 0
    private(set) var isGoogleStatusLoaded: Bool = false
    private(set) var isGoogleDocsReady: Bool = false
    var isPresentingGoogleConnect: Bool = false
    var isPresentingHistory: Bool = false
    var isPresentingShareNumber: Bool = false
    private(set) var sharedDocNumber: String?
    var hasCompletedWelcome: Bool

    let previewStage: DocPreviewStage?

    @ObservationIgnored private let session: any SessionManagerProtocol
    @ObservationIgnored private let coreActions: any CoreActions
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var messagesCancellable: AnyCancellable?
    @ObservationIgnored private var dmMessagesRepository: (any MessagesRepositoryProtocol)?
    @ObservationIgnored private var googleStatusCancellable: AnyCancellable?
    @ObservationIgnored private var observedDmConversationId: String?
    @ObservationIgnored private var latestStateMessageId: String?
    @ObservationIgnored private var stateMessageIdAtLastSend: String?
    @ObservationIgnored private var processedEventMessageIds: Set<String> = []
    @ObservationIgnored private var resolvedItemIds: Set<String> = []
    @ObservationIgnored private var itemsNeedingHistoryReconciliation: Set<String> = []
    @ObservationIgnored private var docContentTimeoutTasks: [String: Task<Void, Never>] = [:]

    init(
        session: any SessionManagerProtocol,
        coreActions: any CoreActions,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.coreActions = coreActions
        self.defaults = defaults
        self.previewStage = DocPreviewStage.current
        self.hasCompletedWelcome = defaults.bool(forKey: Self.key("welcome", session: session))

        if let previewStage,
           [
               DocPreviewStage.cards,
               .forYou,
               .share,
               .disconnected,
               .roomUnbound,
               .roomBound,
               .docSheet,
           ].contains(previewStage) {
            state = Self.previewState
            if [.forYou, .roomBound, .docSheet].contains(previewStage) {
                pendingItems = Self.previewItems
            }
            if [.roomBound, .docSheet].contains(previewStage) {
                docContentsById = Dictionary(
                    uniqueKeysWithValues: Self.previewContents.map { ($0.docId, $0) }
                )
            }
            if previewStage == .share {
                sharedDocNumber = Self.previewNumber
                isPresentingShareNumber = true
            }
        } else if previewStage == nil,
                  let data = defaults.data(forKey: Self.key("snapshot", session: session)),
                  let snapshot = try? JSONDecoder().decode(PersistedSnapshot.self, from: data) {
            state = snapshot.state
            pendingItems = snapshot.pendingItems
            docContentsById = Dictionary(
                uniqueKeysWithValues: (snapshot.docContents ?? []).map { ($0.docId, $0) }
            )
            resolvedItemIds = Set(snapshot.resolvedItemIds)
            itemsNeedingHistoryReconciliation = Set(snapshot.pendingItems.map(\.id))
        } else if previewStage == nil,
                  let data = defaults.data(forKey: Self.key("state", session: session)) {
            state = try? JSONDecoder().decode(DocState.self, from: data)
        }
    }

    var docs: [DocStatus] {
        (state?.docs ?? []).sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    var visiblePendingItems: [DocWaitingItem] {
        pendingItems
            .filter { item in
                guard case .awaitingDelivery = itemSendStates[item.id] else { return true }
                return false
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var previewInitialDoc: DocStatus? {
        switch previewStage {
        case .roomUnbound:
            return docs.first { $0.binding.state == .none }
        case .roomBound, .docSheet:
            return docs.first { $0.binding.state == .live }
        default:
            return nil
        }
    }

    var shouldShowGoogleConnectCard: Bool {
        if previewStage == .disconnected { return true }
        return previewStage == nil && isGoogleStatusLoaded && !isGoogleDocsReady
    }

    var isDmReadyForDisplay: Bool {
        dmViewModel != nil || previewStage != nil
    }

    var shareText: String? {
        guard let sharedDocNumber else { return nil }
        return "Add Doc to our group so the doc stays updated: \(sharedDocNumber)"
    }

    var agentInboxId: String? {
        originViewModel?.conversation.members.first(where: \.isAgent)?.profile.inboxId
    }

    var agentBindingKey: String {
        let originId = originViewModel?.conversation.id ?? "waiting"
        return "\(originId)|\(agentInboxId ?? "waiting")"
    }

    var dmViewModel: ConversationViewModel? {
        agentDmSession?.dmViewModel
    }

    var isPreparingAgent: Bool {
        previewStage == nil && hasCompletedWelcome && dmViewModel == nil
    }

    var googleConnectConversation: Conversation? {
        dmViewModel?.conversation
    }

    private var originViewModel: ConversationViewModel? {
        conversationViewModel?.conversationViewModel
    }

    func completeWelcome() {
        hasCompletedWelcome = true
        guard previewStage == nil else { return }
        defaults.set(true, forKey: Self.key("welcome", session: session))
        Task { await startAgentIfNeeded() }
    }

    func startAgentIfNeeded() async {
        guard previewStage == nil, hasCompletedWelcome, conversationViewModel == nil else { return }

        let storedId = defaults.string(forKey: Self.key("originConversationId", session: session))
        let conversations = try? await session
            .conversationsRepository(for: [.allowed, .unknown])
            .fetchAll()
        let existingId = storedId.flatMap { id in
            conversations?.contains(where: { $0.id == id }) == true ? id : nil
        }
        let mode: NewConversationMode = if let existingId {
            .existingConversation(conversationId: existingId)
        } else {
            .newConversation
        }

        conversationViewModel = NewConversationViewModel(
            session: session,
            mode: mode,
            coreActions: coreActions,
            agentVariantSlug: FeatureFlags.shared.effectiveAgentVariantSlug
        )
    }

    func synchronizeAgentDm() async {
        guard previewStage == nil, let originViewModel else { return }
        persistOriginConversationId(originViewModel.conversation.id)

        let dmSession = agentDmSession ?? AgentDmSession(originViewModel: originViewModel)
        if agentDmSession == nil {
            agentDmSession = dmSession
        }
        dmSession.updateOrigin(originViewModel)
        dmSession.setAgent(inboxId: agentInboxId)
        await dmSession.refreshDefaultAgentProvisioning()
        await dmSession.rebindWhenDmAppears()
        observeDmIfReady()
    }

    func showGoogleConnectIfNeeded() {
        guard previewStage == nil,
              dmViewModel != nil,
              !defaults.bool(forKey: Self.key("googleConnectHandled", session: session)) else {
            return
        }
        isPresentingGoogleConnect = true
    }

    func didDismissGoogleConnect() {
        isPresentingGoogleConnect = false
        guard previewStage == nil else { return }
        defaults.set(true, forKey: Self.key("googleConnectHandled", session: session))
    }

    func didSend(screenshotCount: Int) {
        guard screenshotCount > 0 else { return }
        pendingScreenshotCount = screenshotCount
        stateMessageIdAtLastSend = latestStateMessageId
    }

    func presentShareNumber(for doc: DocStatus) {
        let directNumber = doc.binding.number.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackNumber = docs
            .lazy
            .map(\.binding.number)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        guard let number = directNumber.isEmpty ? fallbackNumber : directNumber,
              !number.isEmpty else {
            return
        }
        sharedDocNumber = number
        isPresentingShareNumber = true
    }

    func sendAnswer(_ answer: DocAnswer, for item: DocWaitingItem) {
        guard let dmViewModel,
              pendingItems.contains(where: { $0.id == item.id }),
              let text = DocAnswerMessage.encode(itemId: item.id, answer: answer) else {
            return
        }
        let clientMessageId = UUID().uuidString
        itemSendStates[item.id] = .resolving(answer: answer, clientMessageId: clientMessageId)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await dmViewModel.sendDocProtocolText(text, clientMessageId: clientMessageId)
                try? await Task.sleep(for: .milliseconds(650))
                guard itemSendStates[item.id] == .resolving(
                    answer: answer,
                    clientMessageId: clientMessageId
                ) else {
                    return
                }
                itemSendStates[item.id] = .awaitingDelivery(
                    answer: answer,
                    clientMessageId: clientMessageId
                )
            } catch {
                itemSendStates[item.id] = .failed(answer: answer)
            }
        }
    }

    func retryAnswer(for item: DocWaitingItem) {
        guard case .failed(let answer) = itemSendStates[item.id] else { return }
        sendAnswer(answer, for: item)
    }

    func sendState(for item: DocWaitingItem) -> DocItemSendState? {
        itemSendStates[item.id]
    }

    func pendingItems(for docId: String) -> [DocWaitingItem] {
        visiblePendingItems.filter { $0.docId == docId }
    }

    func currentDoc(for id: String, fallback: DocStatus) -> DocStatus {
        docs.first(where: { $0.id == id }) ?? fallback
    }

    func content(for docId: String) -> DocContent? {
        docContentsById[docId]
    }

    func contentLoadState(for docId: String) -> DocContentLoadState {
        docContentLoadStates[docId] ?? .idle
    }

    func openRoom(for doc: DocStatus) {
        guard previewStage == nil else { return }
        if let cachedDate = docContentsById[doc.id]?.updatedAt,
           doc.updatedAt <= cachedDate {
            return
        }
        requestDocContent(for: doc.id)
    }

    func retryDocContent(for docId: String) {
        requestDocContent(for: docId)
    }

    func sendScopedInstruction(_ instruction: String, for doc: DocStatus) async -> Bool {
        let cleanInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInstruction.isEmpty else { return false }
        return await sendProtocolText("\(doc.name): \(cleanInstruction)")
    }

    func sendQuestion(_ question: String, excerpt: String, for doc: DocStatus) async -> Bool {
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanExcerpt = excerpt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !cleanQuestion.isEmpty, !cleanExcerpt.isEmpty else { return false }
        return await sendProtocolText("Re \"\(cleanExcerpt)\" in \(doc.name): \(cleanQuestion)")
    }

    private func requestDocContent(for docId: String) {
        guard docContentLoadStates[docId] != .loading else { return }
        guard let dmViewModel else {
            docContentLoadStates[docId] = .idle
            return
        }
        guard let request = DocContentRequestMessage.encode(docId: docId) else {
            docContentLoadStates[docId] = .failed
            return
        }

        docContentLoadStates[docId] = .loading
        docContentTimeoutTasks[docId]?.cancel()
        docContentTimeoutTasks[docId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled,
                  self?.docContentLoadStates[docId] == .loading else {
                return
            }
            self?.docContentLoadStates[docId] = .failed
        }

        Task { @MainActor [weak self] in
            do {
                try await dmViewModel.sendDocProtocolText(
                    request,
                    clientMessageId: UUID().uuidString
                )
            } catch {
                self?.docContentTimeoutTasks[docId]?.cancel()
                self?.docContentTimeoutTasks[docId] = nil
                self?.docContentLoadStates[docId] = .failed
            }
        }
    }

    private func sendProtocolText(_ text: String) async -> Bool {
        if previewStage != nil { return true }
        guard let dmViewModel else { return false }
        do {
            try await dmViewModel.sendDocProtocolText(
                text,
                clientMessageId: UUID().uuidString
            )
            return true
        } catch {
            return false
        }
    }

    private func observeDmIfReady() {
        guard let dmViewModel,
              dmViewModel.conversation.id != observedDmConversationId else {
            showGoogleConnectIfNeeded()
            return
        }
        observedDmConversationId = dmViewModel.conversation.id
        let repository = session.messagesRepository(for: dmViewModel.conversation.id)
        dmMessagesRepository = repository
        messagesCancellable = repository
            .messagesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                guard let self else { return }
                ingest(messages)
                reconcilePersistedItemsIfNeeded()
            }
        observeGoogleStatus(conversationId: dmViewModel.conversation.id)
        showGoogleConnectIfNeeded()
    }

    private func ingest(_ messages: [AnyMessage]) {
        updateAnswerDeliveries(from: messages)
        guard let agentInboxId else { return }

        var changedSnapshot = false
        for message in messages.sorted(by: { $0.date < $1.date }) {
            guard !processedEventMessageIds.contains(message.id),
                  message.senderId == agentInboxId,
                  case .text(let text) = message.content,
                  let event = DocStateMessage.parseEvent(text) else {
                continue
            }
            processedEventMessageIds.insert(message.id)

            switch event {
            case .state(let newState):
                latestStateMessageId = message.id
                state = newState
                changedSnapshot = true
                if pendingScreenshotCount > 0,
                   message.id != stateMessageIdAtLastSend {
                    pendingScreenshotCount = 0
                    stateMessageIdAtLastSend = nil
                }
            case .item(let item):
                guard !resolvedItemIds.contains(item.id) else { continue }
                pendingItems.removeAll { $0.id == item.id }
                pendingItems.append(item)
                changedSnapshot = true
            case .itemResolved(let id):
                resolveItem(id: id)
                changedSnapshot = true
            case .docContent(let content):
                let cached = docContentsById[content.docId]
                let accepted = cached.map { content.updatedAt >= $0.updatedAt } ?? true
                if accepted {
                    docContentsById[content.docId] = content
                    changedSnapshot = true
                }
                let requiredDate = state?.docs.first { $0.id == content.docId }?.updatedAt
                let satisfiesCurrentState = requiredDate.map { content.updatedAt >= $0 } ?? true
                if accepted, satisfiesCurrentState {
                    docContentLoadStates[content.docId] = .idle
                    docContentTimeoutTasks[content.docId]?.cancel()
                    docContentTimeoutTasks[content.docId] = nil
                }
            }
        }
        if changedSnapshot { persistSnapshot() }
    }

    private func updateAnswerDeliveries(from messages: [AnyMessage]) {
        for (itemId, sendState) in Array(itemSendStates) {
            let clientMessageId: String
            let answer: DocAnswer
            switch sendState {
            case let .resolving(currentAnswer, currentMessageId),
                 let .awaitingDelivery(currentAnswer, currentMessageId):
                clientMessageId = currentMessageId
                answer = currentAnswer
            case .failed:
                continue
            }
            guard let message = messages.first(where: { $0.id == clientMessageId }) else { continue }
            switch message.status {
            case .published:
                resolveItem(id: itemId)
                persistSnapshot()
            case .failed:
                itemSendStates[itemId] = .failed(answer: answer)
            case .unpublished, .unknown:
                break
            }
        }
    }

    private func resolveItem(id: String) {
        pendingItems.removeAll { $0.id == id }
        itemSendStates[id] = nil
        resolvedItemIds.insert(id)
        itemsNeedingHistoryReconciliation.remove(id)
    }

    /// A cold snapshot can outlive a resolve event that has moved beyond the
    /// repository's first page. Page backward only for items restored from disk;
    /// live items continue on the inexpensive current-page observation path.
    private func reconcilePersistedItemsIfNeeded() {
        let currentIds = Set(pendingItems.map(\.id))
        itemsNeedingHistoryReconciliation.formIntersection(currentIds)
        guard !itemsNeedingHistoryReconciliation.isEmpty,
              let dmMessagesRepository else {
            return
        }
        guard dmMessagesRepository.hasMoreMessages else {
            itemsNeedingHistoryReconciliation.removeAll()
            return
        }
        try? dmMessagesRepository.fetchPrevious()
    }

    private func observeGoogleStatus(conversationId: String) {
        isGoogleStatusLoaded = false
        isGoogleDocsReady = false
        let repository = session.cloudConnectionRepository()
        googleStatusCancellable = repository.connectionsPublisher()
            .combineLatest(repository.grantsPublisher(for: conversationId))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections, grants in
                guard let self else { return }
                let googleConnectionIds = Set(
                    connections
                        .filter { $0.serviceId == "googledocs" }
                        .map(\.id)
                )
                isGoogleDocsReady = grants.contains { grant in
                    grant.serviceId == "googledocs" &&
                        googleConnectionIds.contains(grant.connectionId) &&
                        grant.grantedToInboxId == agentInboxId
                }
                isGoogleStatusLoaded = true
            }
    }

    private func persistSnapshot() {
        let snapshot = PersistedSnapshot(
            state: state,
            pendingItems: pendingItems,
            resolvedItemIds: Array(resolvedItemIds),
            docContents: Array(docContentsById.values)
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.key("snapshot", session: session))
        }
    }

    private func persistOriginConversationId(_ id: String) {
        guard !id.hasPrefix("draft-") else { return }
        defaults.set(id, forKey: Self.key("originConversationId", session: session))
    }

    private static func key(_ component: String, session: any SessionManagerProtocol) -> String {
        let account: String
        switch session.messagingServiceSync().state {
        case .authorized(let inboxId):
            account = inboxId
        case .registering:
            account = "registering"
        }
        return "doc.v1.\(account).\(component)"
    }

    private struct PersistedSnapshot: Codable {
        let state: DocState?
        let pendingItems: [DocWaitingItem]
        let resolvedItemIds: [String]
        let docContents: [DocContent]?
    }

    private static let previewNumber: String = "+16285550123"

    private static var previewItems: [DocWaitingItem] {
        let now = Date()
        return [
            DocWaitingItem(
                id: "question-dates",
                kind: .question,
                headline: "Which weekend works for everyone?",
                context: "Tahoe Trip needs a date before Doc can update the plan.",
                chips: ["Dec 14", "Dec 21"],
                docId: "tahoe-trip",
                createdAt: now.addingTimeInterval(-4 * 60)
            ),
            DocWaitingItem(
                id: "unknown-sender",
                kind: .unknownContributor,
                headline: "Who sent the cabin address?",
                context: "Name the person so Doc can credit the update.",
                docId: "tahoe-trip",
                createdAt: now.addingTimeInterval(-8 * 60)
            ),
        ]
    }

    private static var previewState: DocState {
        let now = Date()
        return DocState(docs: [
            DocStatus(
                id: "tahoe-trip",
                name: "Tahoe Trip",
                url: "https://docs.google.com/document/d/example-tahoe",
                updatedAt: now.addingTimeInterval(-12 * 60),
                lastChange: DocLastChange(
                    who: "Sara",
                    what: "added flight times",
                    at: now.addingTimeInterval(-12 * 60)
                ),
                binding: DocBinding(
                    state: .live,
                    number: previewNumber,
                    group: "Tahoe Weekend"
                ),
                dates: "Dec 12–15",
                people: 7
            ),
            DocStatus(
                id: "house-projects",
                name: "House Projects",
                url: "https://docs.google.com/document/d/example-house",
                updatedAt: now.addingTimeInterval(-3 * 60 * 60),
                lastChange: DocLastChange(
                    who: "Noah",
                    what: "checked off paint samples",
                    at: now.addingTimeInterval(-3 * 60 * 60)
                ),
                binding: DocBinding(
                    state: .none,
                    number: previewNumber
                ),
                people: 4
            ),
        ])
    }

    private static var previewContents: [DocContent] {
        let now = Date()
        return [
            DocContent(
                docId: "tahoe-trip",
                markdown: """
                # Tahoe Trip

                ## Plan

                Sara lands Friday at 4:30 PM. Meet at the cabin before dinner.

                ## Bring

                - Snow boots
                - Warm layers
                - Board games

                ## Open questions

                Confirm whether everyone prefers December 14 or December 21.
                """,
                changes: [
                    DocLastChange(
                        who: "Sara",
                        what: "added flight times",
                        at: now.addingTimeInterval(-12 * 60)
                    ),
                    DocLastChange(
                        who: "Noah",
                        what: "added the cabin address",
                        at: now.addingTimeInterval(-48 * 60)
                    ),
                    DocLastChange(
                        who: "Mina",
                        what: "started a packing list",
                        at: now.addingTimeInterval(-3 * 60 * 60)
                    ),
                ],
                updatedAt: now.addingTimeInterval(-12 * 60)
            ),
        ]
    }
}
