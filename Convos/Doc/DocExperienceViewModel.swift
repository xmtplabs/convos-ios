import Combine
import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import ConvosMetrics
import Foundation
import UIKit

enum DocComposerScope: Hashable {
    case home
    case room(String)
}

struct DocPendingPhoto: Identifiable {
    let id: UUID
    let image: UIImage

    init(id: UUID = UUID(), image: UIImage) {
        self.id = id
        self.image = image
    }
}

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
    case forYouRegisters
    case draftSheet
    case askSet
    case finishHome
    case finishRoom
    case finishDraft
    case notDocAgent

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

enum DocAgentStartupState: Equatable {
    case idle
    case preparing
    case ready
    case failed(String)
}

struct DocModeConvergenceResult {
    let conversationId: String?
    let canStart: Bool
    let errorMessage: String?
}

struct DocLaneRegistry: Codable, Equatable {
    private(set) var conversationIds: [String: String] = [:]
    private(set) var announcedDocIds: Set<String> = []

    func conversationId(for docId: String) -> String? {
        conversationIds[docId]
    }

    mutating func register(conversationId: String, for docId: String) {
        conversationIds[docId] = conversationId
    }

    mutating func remove(docId: String) {
        conversationIds[docId] = nil
        announcedDocIds.remove(docId)
    }

    func hasAnnounced(docId: String) -> Bool {
        announcedDocIds.contains(docId)
    }

    mutating func takeAnnouncement(for docId: String) -> String? {
        guard !announcedDocIds.contains(docId),
              let message = DocLaneMessage.encode(docId: docId) else {
            return nil
        }
        announcedDocIds.insert(docId)
        return message
    }

    mutating func restoreAnnouncement(for docId: String) {
        announcedDocIds.remove(docId)
    }
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
    private(set) var composerTexts: [DocComposerScope: String] = [:]
    private(set) var composerPhotos: [DocComposerScope: [DocPendingPhoto]] = [:]
    private(set) var pendingScreenshotCount: Int = 0
    private(set) var isGoogleStatusLoaded: Bool = false
    private(set) var isGoogleDocsReady: Bool = false
    private(set) var isConnectingGoogleDocs: Bool = false
    private(set) var googleConnectErrorMessage: String?
    private(set) var isShowingNotDocAgentNotice: Bool = false
    private(set) var agentStartupState: DocAgentStartupState = .idle
    var isPresentingGoogleConnect: Bool = false
    var isPresentingHistory: Bool = false
    var isPresentingShareNumber: Bool = false
    var isPresentingShareDoc: Bool = false
    var presentedDraftItem: DocWaitingItem?
    var activeAnswerItemId: String?
    private(set) var sharedDocNumber: String?
    private(set) var sharedDocText: String?
    var hasCompletedWelcome: Bool

    let previewStage: DocPreviewStage?

    @ObservationIgnored private let session: any SessionManagerProtocol
    @ObservationIgnored private let coreActions: any CoreActions
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var storageAccountIdentifier: String
    @ObservationIgnored private var docMessageAggregator: DocAgentMessageAggregator?
    @ObservationIgnored private var googleStatusCancellable: AnyCancellable?
    @ObservationIgnored private var observedDmConversationId: String?
    @ObservationIgnored private var observedDocAgentInboxId: String?
    @ObservationIgnored private var latestStateMessageId: String?
    @ObservationIgnored private var stateMessageIdAtLastSend: String?
    @ObservationIgnored private var processedEventMessageIds: Set<String> = []
    @ObservationIgnored private var latestStatePosition: DocMessagePosition?
    @ObservationIgnored private var latestItemPositions: [String: DocMessagePosition] = [:]
    @ObservationIgnored private var latestContentPositions: [String: DocMessagePosition] = [:]
    @ObservationIgnored private var resolvedItemIds: Set<String> = []
    @ObservationIgnored private var itemsNeedingHistoryReconciliation: Set<String> = []
    @ObservationIgnored private var docContentTimeoutTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var resetCancellable: AnyCancellable?
    @ObservationIgnored private var notDocAgentNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var compatibilityDetector: DocAgentCompatibilityDetector = .init()
    @ObservationIgnored private var didDismissNotDocAgentNotice: Bool = false
    @ObservationIgnored private var docLaneRegistry: DocLaneRegistry = .init()
    @ObservationIgnored private var docLaneViewModels: [String: ConversationViewModel] = [:]
    @ObservationIgnored private var docLaneProvisionTasks: [String: Task<ConversationViewModel?, Never>] = [:]
    @ObservationIgnored private var agentStartupTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var isStartingAgent: Bool = false

    init(
        session: any SessionManagerProtocol,
        coreActions: any CoreActions,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.coreActions = coreActions
        self.defaults = defaults
        self.previewStage = DocPreviewStage.current
        let initialAccountIdentifier = Self.accountIdentifier(session: session)
        self.storageAccountIdentifier = initialAccountIdentifier
        self.hasCompletedWelcome = defaults.bool(
            forKey: Self.storageKey("welcome", accountIdentifier: initialAccountIdentifier)
        )
        if let data = defaults.data(
            forKey: Self.storageKey("docLanes", accountIdentifier: initialAccountIdentifier)
        ),
           let registry = try? JSONDecoder().decode(DocLaneRegistry.self, from: data) {
            docLaneRegistry = registry
        }

        if let previewStage,
           [
               DocPreviewStage.cards,
               .forYou,
               .share,
               .disconnected,
               .roomUnbound,
               .roomBound,
               .docSheet,
               .forYouRegisters,
               .draftSheet,
               .askSet,
               .finishHome,
               .finishRoom,
               .finishDraft,
           ].contains(previewStage) {
            state = Self.previewState
            if [.forYou, .roomBound, .docSheet].contains(previewStage) {
                pendingItems = Self.previewItems
            } else if [.forYouRegisters, .draftSheet, .finishHome, .finishRoom, .finishDraft]
                .contains(previewStage) {
                pendingItems = Self.previewRegisterItems
            } else if previewStage == .askSet {
                pendingItems = Self.previewAskItems
            }
            if [.roomBound, .docSheet, .finishRoom].contains(previewStage) {
                docContentsById = Dictionary(
                    uniqueKeysWithValues: Self.previewContents.map { ($0.docId, $0) }
                )
            }
            if previewStage == .share {
                sharedDocNumber = Self.previewNumber
                isPresentingShareNumber = true
            }
            if [.draftSheet, .finishDraft].contains(previewStage) {
                presentedDraftItem = pendingItems.first { $0.register == .draft }
            }
        } else if previewStage == nil,
                  let data = defaults.data(
                      forKey: Self.storageKey("snapshot", accountIdentifier: initialAccountIdentifier)
                  ),
                  let snapshot = try? JSONDecoder().decode(PersistedSnapshot.self, from: data) {
            state = snapshot.state
            pendingItems = snapshot.pendingItems
            docContentsById = Dictionary(
                uniqueKeysWithValues: (snapshot.docContents ?? []).map { ($0.docId, $0) }
            )
            resolvedItemIds = Set(snapshot.resolvedItemIds)
            itemsNeedingHistoryReconciliation = Set(snapshot.pendingItems.map(\.id))
            compatibilityDetector.hasSeenDocSentinel = snapshot.hasSeenDocSentinel ??
                (snapshot.state != nil || !snapshot.pendingItems.isEmpty || !(snapshot.docContents ?? []).isEmpty)
        } else if previewStage == nil,
                  let data = defaults.data(
                      forKey: Self.storageKey("state", accountIdentifier: initialAccountIdentifier)
                  ) {
            state = try? JSONDecoder().decode(DocState.self, from: data)
            compatibilityDetector.hasSeenDocSentinel = state != nil
        }

        if previewStage == .notDocAgent {
            isShowingNotDocAgentNotice = true
        }

        resetCancellable = NotificationCenter.default
            .publisher(for: .docAgentResetRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      notification.object as? String == Self.accountIdentifier(session: self.session) else {
                    return
                }
                self.resetRuntimeState(
                    preservingWelcome: notification.userInfo?[Self.preserveWelcomeUserInfoKey] as? Bool == true
                )
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
            .sorted(by: Self.itemPrecedes)
    }

    var previewInitialDoc: DocStatus? {
        switch previewStage {
        case .roomUnbound:
            return docs.first { $0.binding.state == .none }
        case .roomBound, .docSheet, .finishRoom:
            return docs.first { $0.binding.state == .live }
        default:
            return nil
        }
    }

    var shouldShowGoogleConnectCard: Bool {
        if previewStage == .connect || previewStage == .disconnected { return true }
        return previewStage == nil && isGoogleStatusLoaded && !isGoogleDocsReady
    }

    var isDmReadyForDisplay: Bool {
        dmViewModel != nil || previewStage != nil
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
        agentStartupState == .preparing
    }

    var agentStartupErrorMessage: String? {
        guard case .failed(let message) = agentStartupState else { return nil }
        return message
    }

    var googleConnectConversation: Conversation? {
        dmViewModel?.conversation
    }

    private var originViewModel: ConversationViewModel? {
        conversationViewModel?.conversationViewModel
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

    func presentShareNumber(for item: DocWaitingItem) {
        if let docId = item.docId,
           let doc = docs.first(where: { $0.id == docId }) {
            presentShareNumber(for: doc)
            return
        }
        guard let doc = docs.first(where: { !$0.binding.number.isEmpty }) else { return }
        presentShareNumber(for: doc)
    }

    func presentDraft(_ item: DocWaitingItem) {
        guard item.register == .draft, item.draft != nil else { return }
        activeAnswerItemId = nil
        presentedDraftItem = item
    }

    func sendAnswer(_ answer: DocAnswer, for item: DocWaitingItem) {
        guard pendingItems.contains(where: { $0.id == item.id }),
              let text = DocAnswerMessage.encode(itemId: item.id, answer: answer) else {
            return
        }
        let clientMessageId = UUID().uuidString
        itemSendStates[item.id] = .resolving(answer: answer, clientMessageId: clientMessageId)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let targetViewModel: ConversationViewModel?
            if let docId = item.docId {
                targetViewModel = await ensureDocLane(for: docId)
            } else {
                targetViewModel = dmViewModel
            }
            guard let targetViewModel else {
                itemSendStates[item.id] = .failed(answer: answer)
                return
            }
            do {
                try await targetViewModel.sendDocProtocolText(text, clientMessageId: clientMessageId)
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
        Task { @MainActor [weak self] in
            guard let self,
                  await ensureDocLane(for: doc.id) != nil else {
                return
            }
            if let cachedDate = docContentsById[doc.id]?.updatedAt,
               doc.updatedAt <= cachedDate {
                return
            }
            requestDocContent(for: doc.id)
        }
    }

    func retryDocContent(for docId: String) {
        requestDocContent(for: docId)
    }

    func sendScopedInstruction(_ instruction: String, for doc: DocStatus) async -> Bool {
        let cleanInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInstruction.isEmpty else { return false }
        return await sendProtocolText(cleanInstruction, docId: doc.id)
    }

    func sendQuestion(_ question: String, excerpt: String, for doc: DocStatus) async -> Bool {
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanExcerpt = excerpt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !cleanQuestion.isEmpty, !cleanExcerpt.isEmpty else { return false }
        return await sendProtocolText(
            "Re \"\(cleanExcerpt)\" in \(doc.name): \(cleanQuestion)",
            docId: doc.id
        )
    }

    private func requestDocContent(for docId: String) {
        guard docContentLoadStates[docId] != .loading else { return }
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
            guard let self,
                  let laneViewModel = await ensureDocLane(for: docId) else {
                self?.docContentLoadStates[docId] = .idle
                return
            }
            do {
                try await laneViewModel.sendDocProtocolText(
                    request,
                    clientMessageId: UUID().uuidString
                )
            } catch {
                docContentTimeoutTasks[docId]?.cancel()
                docContentTimeoutTasks[docId] = nil
                docContentLoadStates[docId] = .failed
            }
        }
    }

    private func sendProtocolText(_ text: String, docId: String? = nil) async -> Bool {
        if previewStage != nil { return true }
        let targetViewModel: ConversationViewModel?
        if let docId {
            targetViewModel = await ensureDocLane(for: docId)
        } else {
            targetViewModel = dmViewModel
        }
        guard let targetViewModel else { return false }
        do {
            try await targetViewModel.sendDocProtocolText(
                text,
                clientMessageId: UUID().uuidString
            )
            return true
        } catch {
            return false
        }
    }

    func ingestAggregatedMessages(
        _ messages: [AnyMessage],
        agentInboxId: String
    ) {
        updateAnswerDeliveries(from: messages)

        var changedSnapshot = observeAgentCompatibility(messages, agentInboxId: agentInboxId)
        for message in messages.sorted(by: { $0.date < $1.date }) {
            DocWireDebugLog.sentinelReceived(message, expectedSenderId: agentInboxId)
            guard !processedEventMessageIds.contains(message.id),
                  message.senderId == agentInboxId,
                  case .text(let text) = message.content else {
                continue
            }
            guard let event = DocStateMessage.parseEvent(text) else {
                DocWireDebugLog.decodeFailed(text: text, messageId: message.id)
                continue
            }
            processedEventMessageIds.insert(message.id)
            let position = DocMessagePosition(message: message)

            switch event {
            case .state(let newState):
                guard position.isNewer(than: latestStatePosition) else { continue }
                latestStatePosition = position
                latestStateMessageId = message.id
                state = newState
                changedSnapshot = true
                if pendingScreenshotCount > 0,
                   message.id != stateMessageIdAtLastSend {
                    pendingScreenshotCount = 0
                    stateMessageIdAtLastSend = nil
                }
            case .item(let item):
                guard position.isNewer(than: latestItemPositions[item.id]) else { continue }
                latestItemPositions[item.id] = position
                changedSnapshot = DocItemReconciler.apply(
                    event,
                    pendingItems: &pendingItems,
                    resolvedItemIds: &resolvedItemIds
                ) || changedSnapshot
            case .itemResolved(let id):
                guard position.isNewer(than: latestItemPositions[id]) else { continue }
                latestItemPositions[id] = position
                changedSnapshot = DocItemReconciler.apply(
                    event,
                    pendingItems: &pendingItems,
                    resolvedItemIds: &resolvedItemIds
                ) || changedSnapshot
                itemSendStates[id] = nil
                itemsNeedingHistoryReconciliation.remove(id)
            case .docContent(let content):
                guard position.isNewer(than: latestContentPositions[content.docId]) else { continue }
                latestContentPositions[content.docId] = position
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
        updateNotDocAgentNotice()
    }

    private func observeAgentCompatibility(_ messages: [AnyMessage], agentInboxId: String) -> Bool {
        var changed = false
        for message in messages where message.senderId == agentInboxId {
            guard case .text(let text) = message.content else { continue }
            changed = compatibilityDetector.observe(text: text, isAgent: true) || changed
        }
        return changed
    }

    private func updateNotDocAgentNotice() {
        guard previewStage == nil else { return }
        guard compatibilityDetector.shouldWarn, !didDismissNotDocAgentNotice else {
            notDocAgentNoticeTask?.cancel()
            notDocAgentNoticeTask = nil
            isShowingNotDocAgentNotice = false
            return
        }
        guard notDocAgentNoticeTask == nil else { return }
        notDocAgentNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled,
                  let self,
                  self.compatibilityDetector.shouldWarn,
                  !self.didDismissNotDocAgentNotice else {
                return
            }
            self.isShowingNotDocAgentNotice = true
            self.notDocAgentNoticeTask = nil
        }
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
        guard !itemsNeedingHistoryReconciliation.isEmpty else { return }
        let repositories = docMessageAggregator?.repositories ?? []
        let repositoriesWithHistory = repositories.filter(\.hasMoreMessages)
        guard !repositoriesWithHistory.isEmpty else {
            itemsNeedingHistoryReconciliation.removeAll()
            return
        }
        for repository in repositoriesWithHistory {
            try? repository.fetchPrevious()
        }
    }

    private func observeGoogleStatus(conversationId: String) {
        isGoogleStatusLoaded = false
        isGoogleDocsReady = false
        isConnectingGoogleDocs = false
        googleConnectErrorMessage = nil
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
            docContents: Array(docContentsById.values),
            hasSeenDocSentinel: compatibilityDetector.hasSeenDocSentinel
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey("snapshot"))
            DocWireDebugLog.snapshotPersisted(docCount: state?.docs.count ?? 0, itemCount: pendingItems.count, contentCount: docContentsById.count)
        }
    }

    private func persistOriginConversationId(_ id: String) {
        guard !id.hasPrefix("draft-") else { return }
        defaults.set(id, forKey: storageKey("originConversationId"))
    }

    private static func itemPrecedes(_ lhs: DocWaitingItem, _ rhs: DocWaitingItem) -> Bool {
        let lhsRank = registerRank(lhs.register)
        let rhsRank = registerRank(rhs.register)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.createdAt > rhs.createdAt
    }

    private static func registerRank(_ register: DocWaitingItem.Register) -> Int {
        switch register {
        case .waiting: 0
        case .draft: 1
        case .ask: 2
        }
    }

    private struct PersistedSnapshot: Codable {
        let state: DocState?
        let pendingItems: [DocWaitingItem]
        let resolvedItemIds: [String]
        let docContents: [DocContent]?
        let hasSeenDocSentinel: Bool?
    }
}

extension DocExperienceViewModel {
    func completeWelcome() {
        hasCompletedWelcome = true
        guard previewStage == nil else { return }
        defaults.set(true, forKey: storageKey("welcome"))
        Task { await startAgentIfNeeded() }
    }

    func startAgentIfNeeded() async {
        guard previewStage == nil,
              conversationViewModel == nil,
              !isStartingAgent else {
            return
        }
        isStartingAgent = true
        defer { isStartingAgent = false }
        if hasCompletedWelcome {
            agentStartupState = .preparing
            scheduleAgentStartupTimeout()
        }
        guard await activateAuthorizedStorage() else {
            failAgentStartup("Couldn't authorize Doc. Check your connection and try again.")
            return
        }
        guard hasCompletedWelcome else { return }
        agentStartupState = .preparing
        scheduleAgentStartupTimeout()

        let convergence = await convergeDocModeIfNeeded(
            storedId: defaults.string(forKey: storageKey("originConversationId"))
        )
        guard convergence.canStart else {
            failAgentStartup(
                convergence.errorMessage ?? "Doc couldn't start. Check Settings › Debug and try again."
            )
            return
        }
        agentStartupState = .preparing
        scheduleAgentStartupTimeout()
        let storedId = convergence.conversationId

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

    func retryAgentStartup() {
        guard previewStage == nil else { return }
        agentStartupState = .preparing
        scheduleAgentStartupTimeout()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if conversationViewModel == nil {
                await startAgentIfNeeded()
            } else {
                await synchronizeAgentDm()
            }
        }
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
        observeDocAgentMessagesIfReady()
        await dmSession.refreshDefaultAgentProvisioning()
        await dmSession.rebindWhenDmAppears()
        observeDmIfReady()
    }

    func showGoogleConnectIfNeeded() {
        guard previewStage == nil,
              dmViewModel != nil,
              !defaults.bool(forKey: storageKey("googleConnectHandled")) else {
            return
        }
        isPresentingGoogleConnect = true
    }

    func didDismissGoogleConnect() {
        isPresentingGoogleConnect = false
        guard previewStage == nil else { return }
        defaults.set(true, forKey: storageKey("googleConnectHandled"))
    }

    func dismissNotDocAgentNotice() {
        didDismissNotDocAgentNotice = true
        notDocAgentNoticeTask?.cancel()
        notDocAgentNoticeTask = nil
        isShowingNotDocAgentNotice = false
    }
}

extension DocExperienceViewModel {
    func composerText(in scope: DocComposerScope) -> String {
        composerTexts[scope] ?? ""
    }

    func setComposerText(_ text: String, in scope: DocComposerScope) {
        composerTexts[scope] = text
    }

    func pendingPhotos(in scope: DocComposerScope) -> [DocPendingPhoto] {
        composerPhotos[scope] ?? []
    }

    func isComposerReady(in scope: DocComposerScope) -> Bool {
        if previewStage != nil { return true }
        switch scope {
        case .home:
            return dmViewModel != nil
        case .room(let docId):
            return docLaneViewModels[docId] != nil
        }
    }

    func addPendingPhoto(_ image: UIImage, in scope: DocComposerScope) {
        var photos = composerPhotos[scope] ?? []
        photos.append(DocPendingPhoto(image: image))
        composerPhotos[scope] = photos
    }

    func removePendingPhoto(id: UUID, in scope: DocComposerScope) {
        composerPhotos[scope]?.removeAll { $0.id == id }
    }

    func sendComposerDraft(in scope: DocComposerScope) async -> Bool {
        let targetViewModel: ConversationViewModel?
        switch scope {
        case .home:
            targetViewModel = dmViewModel
        case .room(let docId):
            targetViewModel = await ensureDocLane(for: docId)
        }
        guard let targetViewModel else { return false }
        let cleanText = composerText(in: scope).trimmingCharacters(in: .whitespacesAndNewlines)
        let photos = pendingPhotos(in: scope)
        guard !cleanText.isEmpty || !photos.isEmpty else { return false }

        let outgoingText: String? = cleanText.isEmpty ? nil : cleanText
        if !photos.isEmpty { didSend(screenshotCount: photos.count) }

        do {
            try await targetViewModel.sendDocComposerDraft(
                text: outgoingText,
                photos: photos.map(\.image)
            )
            composerTexts[scope] = nil
            composerPhotos[scope] = nil
            return true
        } catch {
            if !photos.isEmpty {
                pendingScreenshotCount = 0
                stateMessageIdAtLastSend = nil
            }
            return false
        }
    }

    private func didSend(screenshotCount: Int) {
        guard screenshotCount > 0 else { return }
        pendingScreenshotCount = screenshotCount
        stateMessageIdAtLastSend = latestStateMessageId
    }
}

private extension DocExperienceViewModel {
    func ensureDocLane(for docId: String) async -> ConversationViewModel? {
        if let viewModel = docLaneViewModels[docId] {
            return await announceLaneIfNeeded(docId: docId, on: viewModel) ? viewModel : nil
        }
        if let task = docLaneProvisionTasks[docId] {
            return await task.value
        }

        let task = Task { @MainActor [weak self] () -> ConversationViewModel? in
            guard let self else { return nil }
            return await provisionDocLane(for: docId)
        }
        docLaneProvisionTasks[docId] = task
        let viewModel = await task.value
        docLaneProvisionTasks[docId] = nil
        return viewModel
    }

    func provisionDocLane(for docId: String) async -> ConversationViewModel? {
        if let conversationId = docLaneRegistry.conversationId(for: docId) {
            if let conversation = try? session.conversationRepository(for: conversationId).fetchConversation() {
                let viewModel = makeDocLaneViewModel(conversation: conversation)
                docLaneViewModels[docId] = viewModel
                return await announceLaneIfNeeded(docId: docId, on: viewModel) ? viewModel : nil
            }
            docLaneRegistry.remove(docId: docId)
            persistDocLaneRegistry()
        }

        guard let agentInboxId else { return nil }
        let messagingService = session.messagingService()
        let stateManager = messagingService.conversationStateManager(
            initialMemberInboxIds: [agentInboxId]
        )
        do {
            try await stateManager.createConversation()
            let conversationId = try await readyConversationId(from: stateManager)
            guard let conversation = try session
                .conversationRepository(for: conversationId)
                .fetchConversation() else {
                return nil
            }
            docLaneRegistry.register(conversationId: conversationId, for: docId)
            persistDocLaneRegistry()
            let viewModel = makeDocLaneViewModel(conversation: conversation)
            docLaneViewModels[docId] = viewModel
            return await announceLaneIfNeeded(docId: docId, on: viewModel) ? viewModel : nil
        } catch {
            Log.error("Doc lane creation failed: \(error.localizedDescription)")
            return nil
        }
    }

    func readyConversationId(
        from stateManager: any ConversationStateManagerProtocol
    ) async throws -> String {
        if case .ready(let result) = stateManager.currentState {
            return result.conversationId
        }
        for await state in stateManager.stateSequence {
            switch state {
            case .ready(let result):
                return result.conversationId
            case .error(let error):
                throw error
            default:
                continue
            }
        }
        throw CancellationError()
    }

    func makeDocLaneViewModel(conversation: Conversation) -> ConversationViewModel {
        ConversationViewModel.createSync(
            conversation: conversation,
            session: session,
            coreActions: coreActions
        )
    }

    func announceLaneIfNeeded(
        docId: String,
        on viewModel: ConversationViewModel
    ) async -> Bool {
        guard !docLaneRegistry.hasAnnounced(docId: docId) else { return true }
        guard let message = docLaneRegistry.takeAnnouncement(for: docId) else { return false }
        do {
            try await viewModel.sendDocProtocolText(
                message,
                clientMessageId: UUID().uuidString
            )
            persistDocLaneRegistry()
            return true
        } catch {
            docLaneRegistry.restoreAnnouncement(for: docId)
            persistDocLaneRegistry()
            Log.error("Doc lane announcement failed: \(error.localizedDescription)")
            return false
        }
    }

    func persistDocLaneRegistry() {
        guard let data = try? JSONEncoder().encode(docLaneRegistry) else { return }
        defaults.set(data, forKey: storageKey("docLanes"))
    }
}

extension DocExperienceViewModel {
    var contributionLine: String? {
        guard let line = state?.line?.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty else {
            return nil
        }
        return line
    }

    var shareText: String? {
        guard let sharedDocNumber else { return nil }
        return "Add Doc to our group so the doc stays updated: \(sharedDocNumber)"
    }

    func presentContributionLine() {
        guard let contributionLine else { return }
        sharedDocNumber = contributionLine
        isPresentingShareNumber = true
    }

    func shouldShowShareDoc(for doc: DocStatus) -> Bool {
        DocShareAction.disposition(for: doc) != .hidden
    }

    @discardableResult
    func shareDoc(_ doc: DocStatus) async -> Bool {
        switch DocShareAction.disposition(for: doc) {
        case .hidden:
            return true
        case .nativeShare(let text):
            sharedDocText = text
            isPresentingShareDoc = true
            return true
        case .askAgent(let text):
            return await sendProtocolText(text, docId: doc.id)
        }
    }

    func connectGoogleDocs() {
        guard previewStage == nil,
              let conversation = googleConnectConversation,
              !isConnectingGoogleDocs else {
            return
        }
        isConnectingGoogleDocs = true
        googleConnectErrorMessage = nil
        let session = session
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let repository = session.cloudConnectionRepository()
                let manager = session.cloudConnectionManager(
                    callbackURLScheme: ConfigManager.shared.appUrlScheme
                )
                let writer = session.messagingService().connectionGrantWriter()
                let agents = conversation.members.filter(\.isAgent).map { $0.profile.inboxId }
                try await DocGoogleConnectionChain.connectAndGrant(
                    existingConnection: {
                        try await repository.connections().first {
                            $0.provider == .composio &&
                                $0.serviceId == "googledocs" &&
                                $0.status == .active
                        }
                    },
                    connect: { try await manager.connect(serviceId: "googledocs") },
                    grant: { connection in
                        for agent in agents {
                            try await writer.grantConnection(
                                connection.id,
                                to: conversation.id,
                                grantedToInboxId: agent
                            )
                        }
                    }
                )
                isGoogleDocsReady = true
                isGoogleStatusLoaded = true
                defaults.set(true, forKey: storageKey("googleConnectHandled"))
            } catch let error as OAuthError {
                if case .cancelled = error {
                    googleConnectErrorMessage = nil
                } else {
                    googleConnectErrorMessage = error.localizedDescription
                }
            } catch {
                googleConnectErrorMessage = error.localizedDescription
            }
            isConnectingGoogleDocs = false
        }
    }
}

enum DocScreenshotSelectionPolicy {
    /// PhotosUI uses `nil` for an unlimited multi-select. The transport sends
    /// each image in sequence, so there is no message-level attachment cap.
    static let maximumSelectionCount: Int? = nil
}

enum DocGoogleConnectionChain {
    @MainActor
    static func connectAndGrant<Connection>(
        existingConnection: () async throws -> Connection?,
        connect: () async throws -> Connection,
        grant: (Connection) async throws -> Void
    ) async throws {
        let connection: Connection
        if let existing = try await existingConnection() {
            connection = existing
        } else {
            connection = try await connect()
        }
        try await grant(connection)
    }
}

extension DocExperienceViewModel {
    private func observeDmIfReady() {
        guard let dmViewModel,
              dmViewModel.conversation.id != observedDmConversationId else {
            showGoogleConnectIfNeeded()
            return
        }
        agentStartupTimeoutTask?.cancel()
        agentStartupTimeoutTask = nil
        agentStartupState = .ready
        observedDmConversationId = dmViewModel.conversation.id
        observeGoogleStatus(conversationId: dmViewModel.conversation.id)
        showGoogleConnectIfNeeded()
    }

    private func observeDocAgentMessagesIfReady() {
        guard let agentInboxId,
              agentInboxId != observedDocAgentInboxId else {
            return
        }
        observedDocAgentInboxId = agentInboxId
        let conversationsRepository = session.conversationsRepository(for: [.allowed, .unknown])
        let aggregator = DocAgentMessageAggregator(
            conversationsPublisher: conversationsRepository
                .conversationsPublisher(containingMemberInboxId: agentInboxId),
            repositoryProvider: { [session] conversationId in
                session.messagesRepository(for: conversationId)
            }
        )
        docMessageAggregator = aggregator
        aggregator.start(agentInboxId: agentInboxId) { [weak self] messages in
            guard let self else { return }
            ingestAggregatedMessages(messages, agentInboxId: agentInboxId)
            reconcilePersistedItemsIfNeeded()
        }
    }

    private func convergeDocModeIfNeeded(storedId: String?) async -> DocModeConvergenceResult {
        guard FeatureFlags.shared.isDocModeEnabled else {
            return DocModeConvergenceResult(
                conversationId: storedId,
                canStart: true,
                errorMessage: nil
            )
        }
        let resolution = await DocModeVariantResolver.resolve()
        if let errorMessage = DocModeResolutionPolicy.enablementError(for: resolution) {
            return DocModeConvergenceResult(
                conversationId: storedId,
                canStart: false,
                errorMessage: errorMessage
            )
        }
        guard case .resolved(let variant) = resolution else {
            return DocModeConvergenceResult(
                conversationId: storedId,
                canStart: false,
                errorMessage: "Doc couldn't resolve its preview runtime."
            )
        }
        let diagnostic = storedId.flatMap { AgentJoinDiagnosticsStore.shared.diagnostic(for: $0) }
        guard DocAgentConvergenceAction.resolve(
            conversationId: storedId,
            diagnostic: diagnostic,
            expectedVariantSlug: variant.slug
        ) == .replace else {
            return DocModeConvergenceResult(
                conversationId: storedId,
                canStart: true,
                errorMessage: nil
            )
        }

        Self.clearAgentBindingStorage(
            session: session,
            defaults: defaults,
            replayFirstRun: false,
            notify: false
        )
        resetRuntimeState(preservingWelcome: true)
        agentStartupState = .preparing
        scheduleAgentStartupTimeout()
        return DocModeConvergenceResult(
            conversationId: nil,
            canStart: true,
            errorMessage: nil
        )
    }

    static func storedOriginConversationId(
        session: any SessionManagerProtocol,
        defaults: UserDefaults = .standard
    ) -> String? {
        defaults.string(forKey: storageKey("originConversationId", session: session))
    }

    static func resetAgentBinding(
        session: any SessionManagerProtocol,
        defaults: UserDefaults = .standard
    ) {
        clearAgentBindingStorage(
            session: session,
            defaults: defaults,
            replayFirstRun: true,
            notify: true
        )
    }

    static func resetAgentBindingForVariantConvergence(
        session: any SessionManagerProtocol,
        defaults: UserDefaults = .standard
    ) {
        clearAgentBindingStorage(
            session: session,
            defaults: defaults,
            replayFirstRun: false,
            notify: true
        )
    }

    private static func clearAgentBindingStorage(
        session: any SessionManagerProtocol,
        defaults: UserDefaults,
        replayFirstRun: Bool,
        notify: Bool
    ) {
        if let conversationId = storedOriginConversationId(session: session, defaults: defaults) {
            AgentJoinDiagnosticsStore.shared.clear(conversationId: conversationId)
        }
        var components = ["originConversationId", "googleConnectHandled", "snapshot", "state", "docLanes"]
        if replayFirstRun {
            components.append("welcome")
        }
        let accountIdentifiers = Set([
            accountIdentifier(session: session),
            provisionalAccountIdentifier,
        ])
        accountIdentifiers
            .flatMap { accountIdentifier in
                components.map { storageKey($0, accountIdentifier: accountIdentifier) }
            }
            .forEach { defaults.removeObject(forKey: $0) }
        guard notify else { return }
        NotificationCenter.default.post(
            name: .docAgentResetRequested,
            object: accountIdentifier(session: session),
            userInfo: [preserveWelcomeUserInfoKey: !replayFirstRun]
        )
    }

    static func storageKey(_ component: String, session: any SessionManagerProtocol) -> String {
        storageKey(component, accountIdentifier: accountIdentifier(session: session))
    }

    static func storageKey(_ component: String, accountIdentifier: String) -> String {
        "doc.v1.\(accountIdentifier).\(component)"
    }

    private static func accountIdentifier(session: any SessionManagerProtocol) -> String {
        switch session.messagingServiceSync().sessionStateManager.currentState {
        case .ready(let result), .backgrounded(let result):
            result.client.inboxId
        default:
            provisionalAccountIdentifier
        }
    }

    private static let persistedComponents: [String] = [
        "welcome",
        "originConversationId",
        "googleConnectHandled",
        "snapshot",
        "state",
        "docLanes",
    ]
    private static let provisionalAccountIdentifier: String = "registering"
    private static let preserveWelcomeUserInfoKey: String = "preserveWelcome"

    private func storageKey(_ component: String) -> String {
        Self.storageKey(component, accountIdentifier: storageAccountIdentifier)
    }

    private func activateAuthorizedStorage() async -> Bool {
        do {
            let result = try await session
                .messagingService()
                .sessionStateManager
                .waitForInboxReadyResult()
            adoptAuthorizedStorage(inboxId: result.client.inboxId)
            return true
        } catch {
            Log.error("Doc storage authorization failed: \(error.localizedDescription)")
            return false
        }
    }

    func adoptAuthorizedStorage(inboxId: String) {
        guard storageAccountIdentifier != inboxId else { return }
        Self.adoptProvisionalStorage(inboxId: inboxId, defaults: defaults)
        storageAccountIdentifier = inboxId
        reloadPersistedState()
    }

    static func adoptProvisionalStorage(inboxId: String, defaults: UserDefaults) {
        for component in persistedComponents {
            let provisionalKey = storageKey(
                component,
                accountIdentifier: provisionalAccountIdentifier
            )
            let authorizedKey = storageKey(component, accountIdentifier: inboxId)
            if defaults.object(forKey: authorizedKey) == nil,
               let provisionalValue = defaults.object(forKey: provisionalKey) {
                defaults.set(provisionalValue, forKey: authorizedKey)
            }
            defaults.removeObject(forKey: provisionalKey)
        }
    }

    private func reloadPersistedState() {
        hasCompletedWelcome = defaults.bool(forKey: storageKey("welcome"))
        if let data = defaults.data(forKey: storageKey("docLanes")),
           let registry = try? JSONDecoder().decode(DocLaneRegistry.self, from: data) {
            docLaneRegistry = registry
        } else {
            docLaneRegistry = .init()
        }

        state = nil
        pendingItems = []
        docContentsById = [:]
        resolvedItemIds = []
        itemsNeedingHistoryReconciliation = []
        compatibilityDetector = .init()
        if let data = defaults.data(forKey: storageKey("snapshot")),
           let snapshot = try? JSONDecoder().decode(PersistedSnapshot.self, from: data) {
            state = snapshot.state
            pendingItems = snapshot.pendingItems
            docContentsById = Dictionary(
                uniqueKeysWithValues: (snapshot.docContents ?? []).map { ($0.docId, $0) }
            )
            resolvedItemIds = Set(snapshot.resolvedItemIds)
            itemsNeedingHistoryReconciliation = Set(snapshot.pendingItems.map(\.id))
            compatibilityDetector.hasSeenDocSentinel = snapshot.hasSeenDocSentinel ??
                (snapshot.state != nil || !snapshot.pendingItems.isEmpty || !(snapshot.docContents ?? []).isEmpty)
        } else if let data = defaults.data(forKey: storageKey("state")) {
            state = try? JSONDecoder().decode(DocState.self, from: data)
            compatibilityDetector.hasSeenDocSentinel = state != nil
        }
    }

    private func scheduleAgentStartupTimeout() {
        agentStartupTimeoutTask?.cancel()
        agentStartupTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled,
                  let self,
                  dmViewModel == nil else {
                return
            }
            failAgentStartup("Doc is taking too long to start. Try again.")
        }
    }

    private func failAgentStartup(_ message: String) {
        agentStartupTimeoutTask?.cancel()
        agentStartupTimeoutTask = nil
        agentStartupState = .failed(message)
    }

    private func resetRuntimeState(preservingWelcome: Bool = false) {
        let completedWelcome = hasCompletedWelcome
        docMessageAggregator?.stop()
        docMessageAggregator = nil
        googleStatusCancellable = nil
        observedDmConversationId = nil
        observedDocAgentInboxId = nil
        conversationViewModel = nil
        agentDmSession = nil
        state = nil
        pendingItems = []
        docContentsById = [:]
        docContentLoadStates = [:]
        itemSendStates = [:]
        composerTexts = [:]
        composerPhotos = [:]
        pendingScreenshotCount = 0
        isGoogleStatusLoaded = false
        isGoogleDocsReady = false
        isPresentingGoogleConnect = false
        isPresentingHistory = false
        isPresentingShareNumber = false
        isPresentingShareDoc = false
        presentedDraftItem = nil
        activeAnswerItemId = nil
        sharedDocNumber = nil
        sharedDocText = nil
        docLaneProvisionTasks.values.forEach { $0.cancel() }
        docLaneProvisionTasks = [:]
        docLaneViewModels = [:]
        docLaneRegistry = .init()
        agentStartupTimeoutTask?.cancel()
        agentStartupTimeoutTask = nil
        agentStartupState = .idle
        hasCompletedWelcome = preservingWelcome ? completedWelcome : false
        latestStateMessageId = nil
        stateMessageIdAtLastSend = nil
        processedEventMessageIds = []
        latestStatePosition = nil
        latestItemPositions = [:]
        latestContentPositions = [:]
        resolvedItemIds = []
        itemsNeedingHistoryReconciliation = []
        docContentTimeoutTasks.values.forEach { $0.cancel() }
        docContentTimeoutTasks = [:]
        notDocAgentNoticeTask?.cancel()
        notDocAgentNoticeTask = nil
        compatibilityDetector = .init()
        didDismissNotDocAgentNotice = false
        isShowingNotDocAgentNotice = false
    }
}

struct DocAgentCompatibilityDetector {
    fileprivate(set) var hasSeenDocSentinel: Bool = false
    private(set) var hasSeenNormalAgentMessage: Bool = false

    var shouldWarn: Bool {
        hasSeenNormalAgentMessage && !hasSeenDocSentinel
    }

    @discardableResult
    mutating func observe(text: String, isAgent: Bool) -> Bool {
        guard isAgent else { return false }
        let oldValue = self
        if DocStateMessage.isDataPlaneText(text) {
            hasSeenDocSentinel = true
        } else if !DocWireMessage.isHiddenText(text) {
            hasSeenNormalAgentMessage = true
        }
        return self != oldValue
    }
}

extension DocAgentCompatibilityDetector: Equatable {}

private extension Notification.Name {
    static let docAgentResetRequested: Notification.Name = Notification.Name(
        "org.convos.docAgentResetRequested"
    )
}

enum DocItemReconciler {
    @discardableResult
    static func apply(
        _ event: DocAgentEvent,
        pendingItems: inout [DocWaitingItem],
        resolvedItemIds: inout Set<String>
    ) -> Bool {
        switch event {
        case .item(let item):
            guard !resolvedItemIds.contains(item.id) else { return false }
            pendingItems.removeAll { $0.id == item.id }
            pendingItems.append(item)
            return true
        case .itemResolved(let id):
            pendingItems.removeAll { $0.id == id }
            resolvedItemIds.insert(id)
            return true
        case .state, .docContent:
            return false
        }
    }
}
