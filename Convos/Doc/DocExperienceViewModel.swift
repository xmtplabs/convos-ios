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

struct DocComposerFocusRequest: Equatable {
    let id: UUID
    let scope: DocComposerScope
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
    case verify
    case verifyPreparing
    case verifyStartupFailure
    case verifyCode
    case verifyFallback
    case verificationHello
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
    case transcript

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

struct DocAnswerSendTarget {
    let conversationId: String
    let performSend: @MainActor (String, String, String) async throws -> Void

    func send(_ text: String, clientMessageId: String) async throws {
        try await performSend(conversationId, text, clientMessageId)
    }
}

enum DocGoogleConnectAvailability: Equatable {
    case preparing
    case ready
    case unavailable
}

struct DocGoogleConnectTarget: Equatable {
    let conversationId: String
    let connectionEventConversationId: String
    let agentInboxIds: [String]

    static func resolve(
        canonicalConversationId: String?,
        connectionEventConversation: Conversation?
    ) -> Self? {
        guard let canonicalConversationId,
              !canonicalConversationId.isEmpty,
              let connectionEventConversation else {
            return nil
        }
        let agentInboxIds = connectionEventConversation.members.filter(\.isAgent).map { $0.profile.inboxId }
        guard !agentInboxIds.isEmpty else { return nil }
        return Self(
            conversationId: canonicalConversationId,
            connectionEventConversationId: connectionEventConversation.id,
            agentInboxIds: agentInboxIds
        )
    }
}

struct DocGoogleConnectEnvironment {
    let target: @MainActor () -> DocGoogleConnectTarget?
    let performConnect: @MainActor (DocGoogleConnectTarget) async throws -> Void
}

struct DocAnswerDeliveryPolicy {
    let awaitingDelay: Duration
    let deadline: Duration

    static let live: Self = .init(
        awaitingDelay: .milliseconds(650),
        deadline: .seconds(15)
    )
}

struct DocVerificationAcknowledgmentPolicy {
    let deadline: Duration

    static let live: Self = .init(deadline: .seconds(25))
}

struct DocGoogleAcknowledgmentPolicy {
    let deadline: Duration

    static let live: Self = .init(deadline: .seconds(25))
}

struct DocVerificationSendTarget {
    let performSend: @MainActor (String) async -> Bool
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

enum DocAgentStartupSurfaceState: Hashable {
    case preparing
    case ready
    case failed(String)

    static func resolve(
        startupState: DocAgentStartupState,
        dmIsReady: Bool
    ) -> Self {
        if case .failed(let message) = startupState { return .failed(message) }
        return dmIsReady ? .ready : .preparing
    }
}

enum DocAgentProvisionRetryPolicy {
    static let attemptDelays: [Duration] = [.zero, .seconds(2)]
}

struct DocRuntimeFallbackWarning: Equatable {
    let requestedSlug: String

    static func resolve(
        isDocModeEnabled: Bool,
        configuredSlug: String? = nil,
        diagnostic: AgentJoinDiagnostic?
    ) -> Self? {
        guard isDocModeEnabled,
              let diagnostic else {
            return nil
        }
        let expectedSlug = configuredSlug ?? diagnostic.requestedVariantId
        guard diagnostic.requestedVariantId != expectedSlug ||
            diagnostic.variantDropped != nil ||
            diagnostic.variant?.slug != expectedSlug else {
            return nil
        }
        return Self(requestedSlug: expectedSlug ?? "unknown")
    }
}

enum DocAgentStartupTimeoutPolicy {
    static let deadline: Duration = .seconds(90)

    static func shouldFail(
        dmIsReady: Bool,
        startupWorkMadeProgress: Bool
    ) -> Bool {
        !dmIsReady && !startupWorkMadeProgress
    }
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
    private(set) var controlSnapshot: DocControlSnapshot?
    private(set) var pendingItems: [DocWaitingItem] = []
    private(set) var docContentsById: [String: DocContent] = [:]
    private(set) var docContentLoadStates: [String: DocContentLoadState] = [:]
    private(set) var itemSendStates: [String: DocItemSendState] = [:]
    private(set) var composerTexts: [DocComposerScope: String] = [:]
    private(set) var composerPhotos: [DocComposerScope: [DocPendingPhoto]] = [:]
    private(set) var pendingScreenshotCount: Int = 0
    private(set) var startingGroupConnectionDocIds: Set<String> = []
    private(set) var isGoogleStatusLoaded: Bool = false
    private(set) var isGoogleDocsReady: Bool = false
    private(set) var isConnectingGoogleDocs: Bool = false
    private(set) var isFinishingGoogleConnect: Bool = false
    private(set) var isGoogleConnectQueued: Bool = false
    private(set) var googleConnectErrorMessage: String?
    private(set) var verificationFlowState: DocVerificationFlowState = .enteringNumber
    private(set) var verificationTransportErrorMessage: String?
    private(set) var isShowingNotDocAgentNotice: Bool = false
    private(set) var agentStartupState: DocAgentStartupState = .idle
    private(set) var agentJoinDiagnostic: AgentJoinDiagnostic?
    var isPresentingGoogleConnect: Bool = false
    var isPresentingHistory: Bool = false
    var isPresentingShareNumber: Bool = false
    var isPresentingShareDoc: Bool = false
    var presentedDraftItem: DocWaitingItem?
    private(set) var presentedDraftComposerScope: DocComposerScope?
    var activeAnswerItemId: String?
    private(set) var composerFocusRequest: DocComposerFocusRequest?
    private(set) var sharedDocNumber: String?
    private(set) var sharedNumberDocName: String?
    private(set) var sharedDocText: String?
    var hasCompletedWelcome: Bool
    private(set) var hasCompletedVerificationHello: Bool
    private(set) var hasCompletedFirstRun: Bool

    let previewStage: DocPreviewStage?

    @ObservationIgnored private let session: any SessionManagerProtocol
    @ObservationIgnored private let coreActions: any CoreActions
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var storageAccountIdentifier: String
    @ObservationIgnored private var docMessageAggregator: DocAgentMessageAggregator?
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
    @ObservationIgnored private var answerDeliveryTimeoutTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var resetCancellable: AnyCancellable?
    @ObservationIgnored private var diagnosticCancellable: AnyCancellable?
    @ObservationIgnored private var notDocAgentNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var compatibilityDetector: DocAgentCompatibilityDetector = .init()
    @ObservationIgnored private var didDismissNotDocAgentNotice: Bool = false
    @ObservationIgnored private var docLaneRegistry: DocLaneRegistry = .init()
    @ObservationIgnored private var docLaneViewModels: [String: ConversationViewModel] = [:]
    @ObservationIgnored private var docLaneProvisionTasks: [String: Task<ConversationViewModel?, Never>] = [:]
    @ObservationIgnored private var agentStartupTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var isStartingAgent: Bool = false
    @ObservationIgnored private var agentStartupProgressRevision: Int = 0
    @ObservationIgnored private var startupGeneration: Int = 0
    private(set) var agentStartupRequestRevision: Int = 0
    @ObservationIgnored private var hasObservedControlEvent: Bool = false
    @ObservationIgnored private var isControlResyncInFlight: Bool = false
    @ObservationIgnored private var queuedVerificationNumber: String?
    @ObservationIgnored private var needsDeterministicAgentProvision: Bool = false
    @ObservationIgnored private var requiresAgentRecreationAfterFailure: Bool = false
    @ObservationIgnored private var hasRetriedRuntimeMismatch: Bool = false
    @ObservationIgnored private var verificationAcknowledgmentTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var verificationAttemptId: UUID?
    @ObservationIgnored private var googleConnectTask: Task<Void, Never>?
    @ObservationIgnored private var googleConnectRequestId: UUID?
    @ObservationIgnored private var googleAcknowledgmentTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var googleAcknowledgmentAttemptId: UUID?
    @ObservationIgnored private let answerSendTargetOverride: DocAnswerSendTarget?
    @ObservationIgnored private let answerDeliveryPolicy: DocAnswerDeliveryPolicy
    @ObservationIgnored private let googleConnectEnvironment: DocGoogleConnectEnvironment?
    @ObservationIgnored private let googleAcknowledgmentPolicy: DocGoogleAcknowledgmentPolicy
    @ObservationIgnored private let verificationAcknowledgmentPolicy: DocVerificationAcknowledgmentPolicy
    @ObservationIgnored private let verificationSendTarget: DocVerificationSendTarget?
    @ObservationIgnored private let agentReadinessOverride: Bool?

    init(
        session: any SessionManagerProtocol,
        coreActions: any CoreActions,
        defaults: UserDefaults = .standard,
        answerSendTarget: DocAnswerSendTarget? = nil,
        answerDeliveryPolicy: DocAnswerDeliveryPolicy = .live,
        googleConnectEnvironment: DocGoogleConnectEnvironment? = nil,
        googleAcknowledgmentPolicy: DocGoogleAcknowledgmentPolicy = .live,
        verificationAcknowledgmentPolicy: DocVerificationAcknowledgmentPolicy = .live,
        verificationSendTarget: DocVerificationSendTarget? = nil,
        agentReadinessOverride: Bool? = nil
    ) {
        self.session = session
        self.coreActions = coreActions
        self.defaults = defaults
        self.answerSendTargetOverride = answerSendTarget
        self.answerDeliveryPolicy = answerDeliveryPolicy
        self.googleConnectEnvironment = googleConnectEnvironment
        self.googleAcknowledgmentPolicy = googleAcknowledgmentPolicy
        self.verificationAcknowledgmentPolicy = verificationAcknowledgmentPolicy
        self.verificationSendTarget = verificationSendTarget
        self.agentReadinessOverride = agentReadinessOverride
        self.previewStage = DocPreviewStage.current
        let initialAccountIdentifier = Self.accountIdentifier(session: session)
        self.storageAccountIdentifier = initialAccountIdentifier
        self.hasCompletedWelcome = Self.initialWelcomeCompletion(
            previewStage: previewStage,
            defaults: defaults,
            accountIdentifier: initialAccountIdentifier
        )
        self.hasCompletedVerificationHello = defaults.bool(
            forKey: Self.storageKey("verificationHello", accountIdentifier: initialAccountIdentifier)
        )
        self.hasCompletedFirstRun = defaults.bool(
            forKey: Self.storageKey("firstRun", accountIdentifier: initialAccountIdentifier)
        )
        self.controlSnapshot = Self.initialControlSnapshot(
            previewStage: previewStage,
            defaults: defaults,
            accountIdentifier: initialAccountIdentifier
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
                controlSnapshot = previewStage == .forYou ? Self.previewVerificationSnapshot : controlSnapshot
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
                sharedDocNumber = DocPreviewConfiguration.contributionLine
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
        if controlSnapshot != nil {
            compatibilityDetector.hasSeenDocSentinel = true
        }

        if previewStage == .notDocAgent {
            isShowingNotDocAgentNotice = true
        }
        restoreVerificationFlow()
        refreshGoogleControlState()
        reconcileFirstRunCompletion()

        observeRuntimeChanges()
    }
}

extension DocExperienceViewModel {
    var firstRunStep: DocFirstRunStep {
        switch previewStage {
        case .welcome:
            return hasCompletedWelcome ? .verify : .welcome
        case .verify, .verifyPreparing, .verifyStartupFailure, .verifyCode, .verifyFallback:
            return .verify
        case .verificationHello:
            return .sayHello
        case .connect:
            return .connectGoogle
        case .some:
            return .home
        case nil:
            return DocFirstRunReducer.step(
                agentIsReady: agentIsReadyForFirstRun,
                hasCompletedWelcome: hasCompletedWelcome,
                hasCompletedFirstRun: hasCompletedFirstRun,
                hasVerifiedNumber: hasVerifiedNumber,
                hasCompletedVerificationHello: hasCompletedVerificationHello,
                hasGrantedGoogleDocs: hasGrantedGoogleDocs
            )
        }
    }

    var visiblePendingItems: [DocWaitingItem] {
        pendingItems
            .filter { item in
                guard item.kind != .verifyNumber else { return false }
                guard case .awaitingDelivery = itemSendStates[item.id] else { return true }
                return false
            }
            .sorted(by: Self.itemPrecedes)
    }

    var controlLifecycle: DocControlLifecycle? {
        controlSnapshot?.lifecycle
    }

    var verificationControl: DocControlVerification? {
        guard let controlSnapshot,
              !controlSnapshot.verificationsByKey.contains(where: { key, verification in
                  key.hasPrefix("verification:owner:") && verification.status == .verified
              }),
              let verification = controlSnapshot.verificationChallenge,
              [.pending, .expired].contains(verification.status) else {
            return nil
        }
        return verification
    }

    var verificationLineNumber: String {
        if let verified = controlSnapshot?.verificationsByKey.values.first(where: { $0.status == .verified }) {
            return verified.lineNumber
        }
        return verificationControl?.lineNumber ?? contributionLine
    }

    var rememberedVerificationNumber: String? {
        defaults.string(forKey: storageKey(Self.verificationNumberComponent))
    }

    func controlBinding(for docId: String) -> DocControlBinding? {
        if let binding = controlSnapshot?.binding(forDocId: docId) { return binding }
        guard previewStage != nil,
              let editorialBinding = docs.first(where: { $0.id == docId })?.binding,
              editorialBinding.state != .none else {
            return nil
        }
        let status: DocControlBinding.Status = editorialBinding.state == .live ? .live : .pending
        return DocControlBinding(
            status: status,
            lineNumber: editorialBinding.number,
            threadId: status == .live ? "preview" : nil,
            conversationType: status == .live ? .group : nil,
            groupName: editorialBinding.group,
            docId: docId,
            intentAt: 0,
            boundAt: status == .live ? 0 : nil,
            releasedAt: nil,
            supersedesKey: nil
        )
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
        if previewStage == .disconnected { return true }
        guard previewStage == nil,
              hasCompletedFirstRun,
              googleControl != nil else {
            return false
        }
        return true
    }

    var isWaitingForGoogleApproval: Bool {
        googleControl?.gate.status == .pending
    }

    var canRequestGoogleDocs: Bool {
        guard googleControl?.gate.status != .pending else {
            return false
        }
        return !isConnectingGoogleDocs
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

    var googleConnectConversation: Conversation? {
        dmViewModel?.conversation
    }

    private var googleConnectTarget: DocGoogleConnectTarget? {
        if let googleConnectEnvironment {
            return googleConnectEnvironment.target()
        }
        return DocGoogleConnectTarget.resolve(
            canonicalConversationId: controlLifecycle?.conversationId,
            connectionEventConversation: googleConnectConversation
        )
    }

    private var googleControl: DocControlGoogleDocs? {
        controlSnapshot?.googleDocs(ownerInboxId: storageAccountIdentifier)
    }

    private var hasVerifiedNumber: Bool {
        controlSnapshot?.verificationsByKey.values.contains(where: { $0.status == .verified }) == true
    }

    private var hasGrantedGoogleDocs: Bool {
        googleControl?.connection.status == .granted
    }

    private var originViewModel: ConversationViewModel? {
        conversationViewModel?.conversationViewModel
    }

    func presentShareNumber(for doc: DocStatus) {
        guard docs.contains(where: { $0.id == doc.id }) else { return }
        let number = relationship(for: doc).lineNumber ?? contributionLine
        guard !number.isEmpty else { return }
        sharedDocNumber = number
        sharedNumberDocName = doc.name
        isPresentingShareNumber = true
    }

    func presentShareNumber(for item: DocWaitingItem) {
        if let docId = item.docId,
           let doc = docs.first(where: { $0.id == docId }) {
            presentShareNumber(for: doc)
            return
        }
        guard let doc = docs.first else { return }
        presentShareNumber(for: doc)
    }

    func presentDraft(_ item: DocWaitingItem, composerScope: DocComposerScope) {
        guard item.register == .draft, item.draft != nil else { return }
        activeAnswerItemId = nil
        presentedDraftComposerScope = composerScope
        presentedDraftItem = item
    }

    func prefillDraftFeedback(for item: DocWaitingItem, in scope: DocComposerScope) {
        guard let draft = item.draft else { return }
        let docName = item.docId
            .flatMap { docId in docs.first(where: { $0.id == docId })?.name } ?? "this doc"
        composerTexts[scope] = DocDraftFeedbackPrompt.message(
            draftSource: draft.text,
            docName: docName
        )
        composerFocusRequest = DocComposerFocusRequest(id: UUID(), scope: scope)
    }

    func sendAnswer(_ answer: DocAnswer, for item: DocWaitingItem) {
        guard pendingItems.contains(where: { $0.id == item.id }),
              let text = DocAnswerMessage.encode(itemId: item.id, answer: answer) else {
            return
        }
        if item.kind == .bindGroup,
           answer == .choice("Bind group"),
           let docId = item.docId {
            startingGroupConnectionDocIds.insert(docId)
        }
        let clientMessageId = UUID().uuidString
        itemSendStates[item.id] = .resolving(answer: answer, clientMessageId: clientMessageId)

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard pendingItems.contains(where: { $0.id == item.id }),
                  itemSendStates[item.id] == .resolving(
                      answer: answer,
                      clientMessageId: clientMessageId
                  ) else {
                return
            }
            guard let answerSendTarget else {
                itemSendStates[item.id] = .failed(answer: answer)
                clearStartingGroupConnection(for: item)
                return
            }
            do {
                try await answerSendTarget.send(text, clientMessageId: clientMessageId)
                try? await Task.sleep(for: answerDeliveryPolicy.awaitingDelay)
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
                scheduleAnswerDeliveryTimeout(
                    itemId: item.id,
                    answer: answer,
                    clientMessageId: clientMessageId
                )
            } catch {
                itemSendStates[item.id] = .failed(answer: answer)
                clearStartingGroupConnection(for: item)
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
        prepareControlProjection(agentInboxId: agentInboxId)
        updateAnswerDeliveries(from: messages)

        var changedSnapshot = observeAgentCompatibility(messages, agentInboxId: agentInboxId)
        var changedControlSnapshot = false
        for message in messages.sorted(by: { $0.date < $1.date }) {
            DocWireDebugLog.sentinelReceived(message, expectedSenderId: agentInboxId)
            guard !processedEventMessageIds.contains(message.id),
                  message.senderId == agentInboxId,
                  case .text(let text) = message.content else {
                continue
            }
            if let controlEvent = DocControlMessage.parseEvent(text) {
                processedEventMessageIds.insert(message.id)
                hasObservedControlEvent = true
                changedControlSnapshot = applyControlEvent(controlEvent) || changedControlSnapshot
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
                // Resolution is terminal for an item ID. A live event may tie
                // an earlier mint's timestamp (or arrive from a clock-skewed
                // hidden lane), so its arrival must not be rejected by the
                // historical ordering guard used for mutable item payloads.
                if position.isNewer(than: latestItemPositions[id]) {
                    latestItemPositions[id] = position
                }
                changedSnapshot = DocItemReconciler.apply(
                    event,
                    pendingItems: &pendingItems,
                    resolvedItemIds: &resolvedItemIds
                ) || changedSnapshot
                cancelAnswerDeliveryTimeout(for: id)
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
        if changedControlSnapshot {
            persistControlSnapshot()
            refreshGoogleControlState()
            reconcileFirstRunCompletion()
            googleConnectTargetDidChange()
        }
        requestControlResyncIfNeeded(agentInboxId: agentInboxId)
        updateNotDocAgentNotice()
    }
}

private extension DocExperienceViewModel {
    func observeRuntimeChanges() {
        resetCancellable = NotificationCenter.default
            .publisher(for: .docAgentResetRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let notificationDefaults = notification.object as? UserDefaults,
                      notificationDefaults === self.defaults,
                      notification.userInfo?[Self.accountIdentifierUserInfoKey] as? String ==
                      Self.accountIdentifier(session: self.session) else {
                    return
                }
                self.hasRetriedRuntimeMismatch = false
                self.resetRuntimeState(
                    preservingWelcome: notification.userInfo?[Self.preserveWelcomeUserInfoKey] as? Bool == true
                )
            }
        diagnosticCancellable = NotificationCenter.default
            .publisher(for: .agentJoinDiagnosticsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.refreshAgentJoinDiagnostic(changedConversationId: notification.object as? String)
            }
        refreshAgentJoinDiagnostic()
    }

    func observeAgentCompatibility(_ messages: [AnyMessage], agentInboxId: String) -> Bool {
        var changed = false
        for message in messages {
            guard case .text(let text) = message.content else { continue }
            if message.senderId == agentInboxId,
               DocControlMessage.parseEvent(text) != nil {
                compatibilityDetector.hasSeenDocSentinel = true
                continue
            }
            let sender: DocAgentCompatibilityDetector.Sender
            if message.senderId == agentInboxId {
                sender = .agent
            } else if message.senderIsCurrentUser {
                sender = .currentUser
            } else {
                continue
            }
            changed = compatibilityDetector.observe(
                text: text,
                sender: sender,
                position: DocMessagePosition(message: message)
            ) || changed
        }
        return changed
    }

    func updateNotDocAgentNotice() {
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

    func updateAnswerDeliveries(from messages: [AnyMessage]) {
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
                cancelAnswerDeliveryTimeout(for: itemId)
                itemSendStates[itemId] = .failed(answer: answer)
            case .unpublished, .unknown:
                break
            }
        }
    }

    func resolveItem(id: String) {
        cancelAnswerDeliveryTimeout(for: id)
        pendingItems.removeAll { $0.id == id }
        itemSendStates[id] = nil
        resolvedItemIds.insert(id)
        itemsNeedingHistoryReconciliation.remove(id)
    }

    /// A cold snapshot can outlive a resolve event that has moved beyond the
    /// repository's first page. Page backward only for items restored from disk;
    /// live items continue on the inexpensive current-page observation path.
    func reconcilePersistedItemsIfNeeded() {
        let currentIds = Set(pendingItems.map(\.id))
        itemsNeedingHistoryReconciliation.formIntersection(currentIds)
        guard state == nil || !itemsNeedingHistoryReconciliation.isEmpty else { return }
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

    func persistSnapshot() {
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

    func persistOriginConversationId(_ id: String) {
        guard !id.hasPrefix("draft-") else { return }
        defaults.set(id, forKey: storageKey("originConversationId"))
        refreshAgentJoinDiagnostic()
    }

    func refreshAgentJoinDiagnostic(changedConversationId: String? = nil) {
        let conversationId = originViewModel?.conversation.id ?? defaults.string(
            forKey: storageKey("originConversationId")
        )
        guard let conversationId,
              changedConversationId == nil || changedConversationId?.caseInsensitiveCompare(conversationId) == .orderedSame else {
            return
        }
        agentJoinDiagnostic = AgentJoinDiagnosticsStore.shared.diagnostic(for: conversationId)
    }

    static func itemPrecedes(_ lhs: DocWaitingItem, _ rhs: DocWaitingItem) -> Bool {
        let lhsRank = registerRank(lhs.register)
        let rhsRank = registerRank(rhs.register)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.createdAt > rhs.createdAt
    }

    static func registerRank(_ register: DocWaitingItem.Register) -> Int {
        switch register {
        case .waiting: 0
        case .draft: 1
        case .ask: 2
        }
    }

    struct PersistedSnapshot: Codable {
        let state: DocState?
        let pendingItems: [DocWaitingItem]
        let resolvedItemIds: [String]
        let docContents: [DocContent]?
        let hasSeenDocSentinel: Bool?
    }

    func prepareControlProjection(agentInboxId: String) {
        let agentKey = storageKey(Self.controlAgentInboxIdComponent)
        guard let persistedAgentInboxId = defaults.string(forKey: agentKey) else {
            defaults.set(agentInboxId, forKey: agentKey)
            return
        }
        guard persistedAgentInboxId != agentInboxId else { return }
        controlSnapshot = nil
        hasObservedControlEvent = false
        isControlResyncInFlight = false
        defaults.removeObject(forKey: storageKey(Self.controlComponent))
        defaults.removeObject(forKey: storageKey(Self.controlResyncMarkerComponent))
        defaults.set(agentInboxId, forKey: agentKey)
        refreshGoogleControlState()
    }

    func applyControlEvent(_ event: DocControlEvent) -> Bool {
        if case .binding(let binding) = event.payload,
           let docId = binding.docId {
            startingGroupConnectionDocIds.remove(docId)
        }
        guard var snapshot = controlSnapshot else {
            controlSnapshot = DocControlSnapshot(event: event)
            applyVerificationControlEvent(event)
            return true
        }
        guard snapshot.apply(event) else { return false }
        controlSnapshot = snapshot
        applyVerificationControlEvent(event)
        return true
    }

    func persistControlSnapshot() {
        guard let controlSnapshot,
              let data = try? JSONEncoder().encode(controlSnapshot) else {
            return
        }
        defaults.set(data, forKey: storageKey(Self.controlComponent))
    }

    func applyVerificationControlEvent(_ event: DocControlEvent) {
        let flowEvent: DocVerificationFlowEvent?
        switch event.payload {
        case .verification(let verification):
            if let number = verification.ownerNumber {
                rememberVerificationNumber(number)
            }
            switch verification.status {
            case .verified:
                flowEvent = .verified(number: verification.ownerNumber)
            case .sent:
                flowEvent = verification.ownerNumber.map(DocVerificationFlowEvent.requestSent)
            case .sendFailed:
                flowEvent = verification.ownerNumber.map(DocVerificationFlowEvent.requestFailed)
            case .attemptFailed:
                flowEvent = verification.ownerNumber.map(DocVerificationFlowEvent.submissionFailed)
            case .pending, .expired, .released:
                flowEvent = nil
            }
        case .binding, .googleDocs, .lifecycle, .line:
            flowEvent = nil
        }
        guard let flowEvent else { return }
        let nextState = DocVerificationFlowReducer.reduce(
            verificationFlowState,
            event: flowEvent
        )
        guard nextState != verificationFlowState else { return }
        cancelVerificationAcknowledgmentTimeout()
        verificationTransportErrorMessage = nil
        verificationFlowState = nextState
    }

    func rememberVerificationNumber(_ number: String) {
        defaults.set(number, forKey: storageKey(Self.verificationNumberComponent))
    }

    func sendVerificationProtocolText(_ text: String) async -> Bool {
        if let verificationSendTarget {
            return await verificationSendTarget.performSend(text)
        }
        return await sendProtocolText(text)
    }

    func scheduleVerificationAcknowledgmentTimeout(
        attemptId: UUID,
        expectedState: DocVerificationFlowState,
        event: DocVerificationFlowEvent,
        message: String
    ) {
        verificationAcknowledgmentTimeoutTask?.cancel()
        let deadline = verificationAcknowledgmentPolicy.deadline
        verificationAcknowledgmentTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return
            }
            guard let self,
                  verificationAttemptId == attemptId,
                  verificationFlowState == expectedState else {
                return
            }
            verificationAcknowledgmentTimeoutTask = nil
            verificationAttemptId = nil
            verificationTransportErrorMessage = message
            verificationFlowState = DocVerificationFlowReducer.reduce(
                verificationFlowState,
                event: event
            )
        }
    }

    func cancelVerificationAcknowledgmentTimeout() {
        verificationAcknowledgmentTimeoutTask?.cancel()
        verificationAcknowledgmentTimeoutTask = nil
        verificationAttemptId = nil
    }

    func refreshGoogleControlState() {
        guard let googleControl else {
            isGoogleStatusLoaded = false
            isGoogleDocsReady = false
            isConnectingGoogleDocs = googleConnectRequestId != nil || isFinishingGoogleConnect
            return
        }
        isGoogleStatusLoaded = true
        isGoogleDocsReady = googleControl.connection.status == .granted
        if isGoogleDocsReady {
            cancelGoogleAcknowledgmentTimeout()
            googleConnectErrorMessage = nil
        }
        isConnectingGoogleDocs = googleControl.gate.status == .pending ||
            googleConnectRequestId != nil ||
            isFinishingGoogleConnect
        if isGoogleDocsReady || googleControl.gate.status == .pending {
            isGoogleConnectQueued = false
        }
    }

    func scheduleGoogleAcknowledgmentTimeout(attemptId: UUID) {
        googleAcknowledgmentTimeoutTask?.cancel()
        let deadline = googleAcknowledgmentPolicy.deadline
        googleAcknowledgmentTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return
            }
            guard let self,
                  googleAcknowledgmentAttemptId == attemptId,
                  !isGoogleDocsReady else {
                return
            }
            googleAcknowledgmentTimeoutTask = nil
            googleAcknowledgmentAttemptId = nil
            isFinishingGoogleConnect = false
            googleConnectErrorMessage = "Couldn't finish connecting Google. Try again."
            refreshGoogleControlState()
        }
    }

    func cancelGoogleAcknowledgmentTimeout() {
        googleAcknowledgmentTimeoutTask?.cancel()
        googleAcknowledgmentTimeoutTask = nil
        googleAcknowledgmentAttemptId = nil
        isFinishingGoogleConnect = false
    }

    func reconcileFirstRunCompletion() {
        guard previewStage == nil,
              !hasCompletedFirstRun,
              DocFirstRunReducer.step(
                  agentIsReady: agentIsReadyForFirstRun,
                  hasCompletedWelcome: hasCompletedWelcome,
                  hasCompletedFirstRun: false,
                  hasVerifiedNumber: hasVerifiedNumber,
                  hasCompletedVerificationHello: hasCompletedVerificationHello,
                  hasGrantedGoogleDocs: hasGrantedGoogleDocs
              ) == .home else {
            return
        }
        hasCompletedFirstRun = true
        defaults.set(true, forKey: storageKey("firstRun"))
    }

    func requestControlResyncIfNeeded(agentInboxId: String) {
        guard previewStage == nil,
              controlSnapshot == nil,
              !hasObservedControlEvent,
              !isControlResyncInFlight,
              defaults.string(forKey: storageKey(Self.controlResyncMarkerComponent)) != agentInboxId,
              let dmViewModel else {
            return
        }
        isControlResyncInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isControlResyncInFlight = false }
            do {
                try await dmViewModel.sendDocProtocolText(
                    DocControlRequestMessage.resyncText,
                    clientMessageId: UUID().uuidString
                )
                defaults.set(agentInboxId, forKey: storageKey(Self.controlResyncMarkerComponent))
            } catch {
                Log.warning("Doc control resync request failed: \(error.localizedDescription)")
            }
        }
    }
}

extension DocExperienceViewModel {
    var docs: [DocStatus] {
        (state?.docs ?? []).sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    var isPreparingAgent: Bool {
        agentStartupState == .preparing
    }

    var agentStartupErrorMessage: String? {
        guard case .failed(let message) = agentStartupState else { return nil }
        return message
    }

    var canConnectGoogleDocs: Bool {
        if previewStage == .connect { return true }
        guard agentStartupErrorMessage == nil else { return false }
        return googleConnectAvailability == .ready
    }

    var isPreparingGoogleConnect: Bool {
        previewStage == nil && googleConnectAvailability == .preparing
    }

    var googleConnectAvailability: DocGoogleConnectAvailability {
        guard canRequestGoogleDocs, agentStartupErrorMessage == nil else { return .unavailable }
        return googleConnectTarget == nil ? .preparing : .ready
    }

    var runtimeFallbackWarning: DocRuntimeFallbackWarning? {
        DocRuntimeFallbackWarning.resolve(
            isDocModeEnabled: FeatureFlags.shared.isDocModeEnabled,
            configuredSlug: FeatureFlags.shared.effectiveAgentVariantSlug,
            diagnostic: agentJoinDiagnostic
        )
    }

    var verificationAgentStartupState: DocAgentStartupSurfaceState {
        if previewStage == .verifyPreparing { return .preparing }
        if previewStage == .verifyStartupFailure {
            return .failed("I couldn't open our private chat. Check your connection and try again.")
        }
        return .resolve(
            startupState: agentStartupState,
            dmIsReady: dmViewModel != nil || previewStage != nil
        )
    }

    var agentPreparationState: DocAgentStartupSurfaceState {
        .resolve(
            startupState: agentStartupState,
            dmIsReady: dmViewModel != nil
        )
    }

    var isPhoneVerificationRequestQueued: Bool {
        queuedVerificationNumber != nil
    }

    func relationship(for doc: DocStatus) -> DocGroupRelationship {
        DocGroupRelationship.project(
            doc: doc,
            controlBinding: controlBinding(for: doc.id),
            isControlLoaded: controlSnapshot != nil || previewStage != nil,
            content: content(for: doc.id)
        )
    }

    var unmatchedGroupProgress: [DocUnmatchedGroupProgress] {
        guard let controlSnapshot else { return [] }
        let candidates: [(key: String, binding: DocControlBinding)] = controlSnapshot.bindingsByKey.compactMap { key, binding in
            guard binding.status == .live,
                  binding.conversationType == .group,
                  binding.docId == nil else {
                return nil
            }
            return (key: key, binding: binding)
        }
        let latest = candidates
        .max { lhs, rhs in
            let lhsDate = lhs.binding.boundAt ?? lhs.binding.intentAt
            let rhsDate = rhs.binding.boundAt ?? rhs.binding.intentAt
            return lhsDate == rhsDate ? lhs.key < rhs.key : lhsDate < rhsDate
        }
        guard let latest else { return [] }
        return [DocUnmatchedGroupProgress(
            id: latest.key,
            groupName: latest.binding.groupName
        )]
    }

    func isStartingGroupConnection(for docId: String) -> Bool {
        startingGroupConnectionDocIds.contains(docId)
    }

    func observedGroupSenders(for docId: String?) -> [String] {
        guard let docId,
              let doc = docs.first(where: { $0.id == docId }) else {
            return []
        }
        return DocGroupIdentity.observedMembers(doc: doc, content: content(for: docId))
    }

    func beginGroupConnection(for doc: DocStatus) {
        guard docs.contains(where: { $0.id == doc.id }),
              !startingGroupConnectionDocIds.contains(doc.id) else {
            return
        }
        let relationship = relationship(for: doc)
        let canStart: Bool
        switch relationship {
        case .standalone, .ended:
            canStart = true
        case .loading, .connecting, .connected:
            canStart = false
        }
        guard canStart else { return }

        startingGroupConnectionDocIds.insert(doc.id)
        if let offer = visiblePendingItems.first(where: {
            $0.register == .ask && $0.kind == .bindGroup && $0.docId == doc.id
        }) {
            sendAnswer(.choice("Bind group"), for: offer)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let didSend = await sendScopedInstruction(
                "Connect \(doc.name) to an iMessage group.",
                for: doc
            )
            if !didSend {
                startingGroupConnectionDocIds.remove(doc.id)
            }
        }
    }

    func completeWelcome() {
        hasCompletedWelcome = true
        guard previewStage == nil else { return }
        defaults.set(true, forKey: storageKey("welcome"))
        reconcileFirstRunCompletion()
    }

    func requestPhoneVerification(number: String) {
        guard let text = DocControlRequestMessage.verifyRequestText(number: number) else { return }
        verificationTransportErrorMessage = nil
        rememberVerificationNumber(number)
        guard dmViewModel != nil || previewStage != nil || verificationSendTarget != nil else {
            queuedVerificationNumber = number
            markAgentStartupProgress()
            return
        }
        queuedVerificationNumber = nil
        performPhoneVerificationRequest(number: number, text: text)
    }

    private func performPhoneVerificationRequest(number: String, text: String) {
        cancelVerificationAcknowledgmentTimeout()
        let attemptId = UUID()
        verificationAttemptId = attemptId
        verificationFlowState = DocVerificationFlowReducer.reduce(
            verificationFlowState,
            event: .request(number: number)
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            let didSend = await sendVerificationProtocolText(text)
            guard verificationAttemptId == attemptId,
                  verificationFlowState == .requesting(number: number) else {
                return
            }
            guard didSend else {
                cancelVerificationAcknowledgmentTimeout()
                verificationTransportErrorMessage = "Couldn't request a code. Check your connection and try again."
                verificationFlowState = DocVerificationFlowReducer.reduce(
                    verificationFlowState,
                    event: .requestTransportFailed
                )
                return
            }
            scheduleVerificationAcknowledgmentTimeout(
                attemptId: attemptId,
                expectedState: .requesting(number: number),
                event: .requestAcknowledgmentTimedOut(number: number),
                message: "Couldn't send the code. Try again."
            )
        }
    }

    func submitPhoneVerification(code: String) {
        guard let number = verificationFlowState.number,
              let text = DocControlRequestMessage.verifySubmitText(code: code) else {
            return
        }
        cancelVerificationAcknowledgmentTimeout()
        let attemptId = UUID()
        verificationAttemptId = attemptId
        verificationTransportErrorMessage = nil
        verificationFlowState = DocVerificationFlowReducer.reduce(
            verificationFlowState,
            event: .submitCode
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            let didSend = await sendVerificationProtocolText(text)
            guard verificationAttemptId == attemptId,
                  verificationFlowState == .submitting(number: number) else {
                return
            }
            guard didSend else {
                cancelVerificationAcknowledgmentTimeout()
                verificationTransportErrorMessage = "Couldn't check that code. Check your connection and try again."
                verificationFlowState = DocVerificationFlowReducer.reduce(
                    verificationFlowState,
                    event: .submissionTransportFailed(number: number)
                )
                return
            }
            scheduleVerificationAcknowledgmentTimeout(
                attemptId: attemptId,
                expectedState: .submitting(number: number),
                event: .submissionAcknowledgmentTimedOut(number: number),
                message: "Couldn't verify the code. Try again."
            )
        }
    }

    func showPhoneVerificationFallback() {
        cancelVerificationAcknowledgmentTimeout()
        verificationTransportErrorMessage = nil
        verificationFlowState = DocVerificationFlowReducer.reduce(
            verificationFlowState,
            event: .showFallback
        )
    }

    func editPhoneNumber() {
        queuedVerificationNumber = nil
        cancelVerificationAcknowledgmentTimeout()
        verificationTransportErrorMessage = nil
        verificationFlowState = DocVerificationFlowReducer.reduce(
            verificationFlowState,
            event: .editNumber
        )
    }

    func completeVerificationHello() {
        hasCompletedVerificationHello = true
        guard previewStage == nil else { return }
        defaults.set(true, forKey: storageKey(Self.verificationHelloComponent))
        reconcileFirstRunCompletion()
    }

    func startAgentIfNeeded() async {
        guard previewStage == nil,
              conversationViewModel == nil,
              !isStartingAgent else {
            return
        }
        let generation = startupGeneration
        isStartingAgent = true
        defer {
            if startupGeneration == generation {
                isStartingAgent = false
            }
        }
        markAgentStartupProgress()
        guard await activateAuthorizedStorage() else {
            guard startupGeneration == generation else { return }
            failAgentStartup("Couldn't authorize Doc. Check your connection and try again.")
            return
        }
        guard startupGeneration == generation else { return }
        markAgentStartupProgress()

        let convergence = await convergeDocModeIfNeeded(
            storedId: defaults.string(forKey: storageKey("originConversationId"))
        )
        guard startupGeneration == generation else { return }
        guard convergence.canStart else {
            failAgentStartup(
                convergence.errorMessage ?? "Doc couldn't start. Check Settings › Debug and try again."
            )
            return
        }
        markAgentStartupProgress()
        let storedId = convergence.conversationId

        let conversations: [Conversation]
        do {
            conversations = try await session
                .conversationsRepository(for: [.allowed, .unknown])
                .fetchAll()
        } catch {
            guard startupGeneration == generation else { return }
            failAgentStartup("Couldn't load Doc's chat. Check your connection and try again.")
            return
        }
        guard startupGeneration == generation else { return }
        let existingId = storedId.flatMap { id in
            conversations.contains(where: { $0.id == id }) ? id : nil
        }
        if storedId != nil, existingId == nil {
            await Self.tearDownAgentBinding(
                session: session,
                defaults: defaults,
                replayFirstRun: false,
                notify: false,
                additionalConversationId: storedId
            )
            resetRuntimeState(preservingWelcome: true, invalidatesStartup: false)
        }
        markAgentStartupProgress()
        let mode: NewConversationMode = if let existingId {
            .existingConversation(conversationId: existingId)
        } else {
            .newConversation
        }
        needsDeterministicAgentProvision = true
        let newConversationViewModel = NewConversationViewModel(
            session: session,
            mode: mode,
            coreActions: coreActions,
            agentVariantSlug: FeatureFlags.shared.effectiveAgentVariantSlug,
            automaticCreationRetryPolicy: .docStartup
        )
        newConversationViewModel.onCreationFailed = { [weak self, weak newConversationViewModel] _ in
            guard let self,
                  let newConversationViewModel,
                  self.conversationViewModel === newConversationViewModel else {
                return
            }
            self.failAgentStartup("I couldn't open our private chat. Check your connection and try again.")
        }
        newConversationViewModel.onAgentProvisionFailed = { [weak self, weak newConversationViewModel] failure in
            guard let self,
                  let newConversationViewModel,
                  self.conversationViewModel === newConversationViewModel else {
                return
            }
            Log.error("Doc agent startup failed: \(failure.reason ?? "no reason given")")
            self.failAgentStartup(
                "I couldn't open our private chat. Check your connection and try again.",
                requiresRecreation: true
            )
        }
        conversationViewModel = newConversationViewModel
        markAgentStartupProgress()
    }

    func retryAgentStartup() {
        guard previewStage == nil else { return }
        guard !requiresAgentRecreationAfterFailure else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                hasRetriedRuntimeMismatch = false
                await Self.tearDownAgentBinding(
                    session: session,
                    defaults: defaults,
                    replayFirstRun: false,
                    notify: false,
                    additionalConversationId: originViewModel?.conversation.id
                )
                resetRuntimeState(preservingWelcome: true)
                await startAgentIfNeeded()
            }
            return
        }
        markAgentStartupProgress(restartsFailedAttempt: true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if conversationViewModel == nil {
                await startAgentIfNeeded()
            } else if conversationViewModel?.currentError != nil {
                conversationViewModel?.retryConversationCreation()
            } else {
                await synchronizeAgentDm()
            }
        }
    }

    func synchronizeAgentDm() async {
        guard previewStage == nil, let originViewModel else { return }
        markAgentStartupProgress()
        let conversationId = originViewModel.conversation.id
        guard !originViewModel.conversation.isDraft else { return }

        if needsDeterministicAgentProvision, agentInboxId == nil {
            await ensureDocAgentProvisioned(conversationId: conversationId)
            guard conversationId == self.originViewModel?.conversation.id else { return }
        }
        guard await validateDocRuntimeIfNeeded(conversationId: conversationId) else { return }
        persistOriginConversationId(conversationId)

        let dmSession = agentDmSession ?? AgentDmSession(originViewModel: originViewModel)
        if agentDmSession == nil {
            agentDmSession = dmSession
        }
        dmSession.updateOrigin(originViewModel)
        dmSession.setAgent(inboxId: agentInboxId)
        observeDocAgentMessagesIfReady()
        await dmSession.refreshDefaultAgentProvisioning()
        markAgentStartupProgress()
        await dmSession.rebindWhenDmAppears { [weak self] in
            self?.markAgentStartupProgress()
        }
        markAgentStartupProgress()
        await observeDmIfReady()
    }

    func showGoogleConnectIfNeeded() {
        guard previewStage == nil,
              dmViewModel != nil,
              shouldShowGoogleConnectCard,
              googleControl?.gate.status != .pending,
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
                photos: photos.map(\.image),
                onPhotoSent: { [weak self] index in
                    guard photos.indices.contains(index) else { return }
                    self?.removePendingPhoto(id: photos[index].id, in: scope)
                }
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
    var answerSendTarget: DocAnswerSendTarget? {
        if let answerSendTargetOverride { return answerSendTargetOverride }
        guard let dmViewModel else { return nil }
        return DocAnswerSendTarget(conversationId: dmViewModel.conversation.id) { _, text, clientMessageId in
            try await dmViewModel.sendDocProtocolText(text, clientMessageId: clientMessageId)
        }
    }

    func scheduleAnswerDeliveryTimeout(
        itemId: String,
        answer: DocAnswer,
        clientMessageId: String
    ) {
        cancelAnswerDeliveryTimeout(for: itemId)
        answerDeliveryTimeoutTasks[itemId] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: answerDeliveryPolicy.deadline)
            guard !Task.isCancelled,
                  itemSendStates[itemId] == .awaitingDelivery(
                      answer: answer,
                      clientMessageId: clientMessageId
                  ) else {
                return
            }
            answerDeliveryTimeoutTasks[itemId] = nil
            itemSendStates[itemId] = .failed(answer: answer)
            if let item = pendingItems.first(where: { $0.id == itemId }) {
                clearStartingGroupConnection(for: item)
            }
        }
    }

    func clearStartingGroupConnection(for item: DocWaitingItem) {
        guard item.kind == .bindGroup, let docId = item.docId else { return }
        startingGroupConnectionDocIds.remove(docId)
    }

    func cancelAnswerDeliveryTimeout(for itemId: String) {
        answerDeliveryTimeoutTasks[itemId]?.cancel()
        answerDeliveryTimeoutTasks[itemId] = nil
    }

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
    var contributionLine: String {
        if let line = controlSnapshot?.line,
           line.status == .available,
           let lineNumber = line.lineNumber {
            return lineNumber
        }
        return previewStage == nil ? "" : DocPreviewConfiguration.contributionLine
    }

    var shareText: String? {
        guard let sharedDocNumber else { return nil }
        guard let sharedNumberDocName else {
            return "Add @doc to this iMessage group: \(docDisplayPhoneNumber(sharedDocNumber))"
        }
        return DocGroupShareCopy.text(
            docName: sharedNumberDocName,
            lineNumber: sharedDocNumber
        )
    }

    func presentContributionLine() {
        guard !contributionLine.isEmpty else { return }
        sharedDocNumber = contributionLine
        sharedNumberDocName = nil
        isPresentingShareNumber = true
    }

    func renewVerification() {
        Task { @MainActor [weak self] in
            _ = await self?.sendProtocolText(DocControlRequestMessage.renewVerificationText)
        }
    }

    func shouldShowShareDoc(for doc: DocStatus) -> Bool {
        DocShareAction.disposition(
            for: doc,
            controlBinding: controlBinding(for: doc.id)
        ) != .hidden
    }

    @discardableResult
    func shareDoc(_ doc: DocStatus) async -> Bool {
        switch DocShareAction.disposition(
            for: doc,
            controlBinding: controlBinding(for: doc.id)
        ) {
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
              canRequestGoogleDocs,
              agentStartupErrorMessage == nil else {
            return
        }
        guard let target = googleConnectTarget else {
            isGoogleConnectQueued = true
            return
        }
        isGoogleConnectQueued = false
        let requestId = UUID()
        googleConnectRequestId = requestId
        isConnectingGoogleDocs = true
        googleConnectErrorMessage = nil
        googleConnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let googleConnectEnvironment {
                    try await googleConnectEnvironment.performConnect(target)
                } else {
                    try await performGoogleConnect(target: target)
                }
                try Task.checkCancellation()
                guard googleConnectRequestId == requestId else { return }
                defaults.set(true, forKey: storageKey("googleConnectHandled"))
                googleConnectRequestId = nil
                googleConnectTask = nil
                googleAcknowledgmentAttemptId = requestId
                isFinishingGoogleConnect = true
                scheduleGoogleAcknowledgmentTimeout(attemptId: requestId)
                refreshGoogleControlState()
            } catch let error as OAuthError {
                guard googleConnectRequestId == requestId else { return }
                if case .cancelled = error {
                    googleConnectErrorMessage = nil
                } else {
                    googleConnectErrorMessage = error.localizedDescription
                }
            } catch is CancellationError {
                guard googleConnectRequestId == requestId else { return }
                googleConnectErrorMessage = "Lost the chat connection. Try again."
            } catch {
                guard googleConnectRequestId == requestId else { return }
                googleConnectErrorMessage = error.localizedDescription
            }
            guard googleConnectRequestId == requestId else { return }
            googleConnectRequestId = nil
            googleConnectTask = nil
            refreshGoogleControlState()
        }
    }

    func googleConnectTargetDidChange() {
        guard isGoogleConnectQueued else { return }
        connectGoogleDocs()
    }

    private func performGoogleConnect(
        target: DocGoogleConnectTarget
    ) async throws {
        let selection = AbilitiesServices.selection
        let catalog = try await selection.service.fetchCatalog()
        try Task.checkCancellation()
        guard let ability = catalog.abilities.first(where: {
            $0.id == DocGoogleConnectionChain.abilityId
        }) else {
            throw AbilitiesServiceError.unknownAbility(abilityId: DocGoogleConnectionChain.abilityId)
        }
        let defaultBundles = ability.bundles.filter(\.defaultEnabled).map(\.id)
        let bundleIds = defaultBundles.isEmpty ? ability.bundles.map(\.id) : defaultBundles
        try await DocGoogleConnectionChain.connectAndExtend(
            entitlementIsActive: ability.entitlement?.status == .active,
            bundleIds: bundleIds,
            beginEntitlement: {
                try Task.checkCancellation()
                return try await selection.service.beginEntitlement(
                    abilityId: DocGoogleConnectionChain.abilityId
                )
            },
            authorize: { redirectUrl in
                try Task.checkCancellation()
                guard let authorizer = selection.authorizer else {
                    throw DocGoogleConnectionChain.Error.authorizationUnavailable
                }
                try await authorizer.authorize(redirectUrl: redirectUrl)
            },
            completeEntitlement: {
                try Task.checkCancellation()
                try await selection.service.completeEntitlement(abilityId: DocGoogleConnectionChain.abilityId)
            },
            extend: { bundleIds in
                try Task.checkCancellation()
                for agentInboxId in target.agentInboxIds {
                    try await selection.service.extendAbility(
                        conversationId: target.conversationId,
                        abilityId: DocGoogleConnectionChain.abilityId,
                        agentInboxId: agentInboxId,
                        bundleIds: bundleIds
                    )
                }
            }
        )
        try Task.checkCancellation()
        try await DocGoogleConnectionChain.sendGrantedEvents(
            target: target,
            eventWriter: session.messagingService().connectionEventWriter()
        )
    }
}

enum DocScreenshotSelectionPolicy {
    /// PhotosUI uses `nil` for an unlimited multi-select. The transport sends
    /// each image in sequence, so there is no message-level attachment cap.
    static let maximumSelectionCount: Int? = nil
}

enum DocGoogleConnectionChain {
    static let abilityId: String = "googledocs"
    static let providerId: ProviderID = .init(rawValue: "composio.\(abilityId)")

    enum Error: LocalizedError {
        case authorizationUnavailable
        case missingAuthorizationURL
        case noPermissionBundles

        var errorDescription: String? {
            switch self {
            case .authorizationUnavailable:
                "Google sign-in is unavailable. Try again."
            case .missingAuthorizationURL:
                "Google sign-in couldn't start. Try again."
            case .noPermissionBundles:
                "Google Docs permissions are unavailable. Try again later."
            }
        }
    }

    @MainActor
    static func connectAndExtend(
        entitlementIsActive: Bool,
        bundleIds: [String],
        beginEntitlement: () async throws -> AbilityEntitlementInitiation,
        authorize: (String) async throws -> Void,
        completeEntitlement: () async throws -> Void,
        extend: ([String]) async throws -> Void
    ) async throws {
        guard !bundleIds.isEmpty else { throw Error.noPermissionBundles }
        if !entitlementIsActive {
            let initiation = try await beginEntitlement()
            if initiation.status == .pendingAuth {
                guard let redirectUrl = initiation.redirectUrl else {
                    throw Error.missingAuthorizationURL
                }
                try await authorize(redirectUrl)
                try await completeRetryingAuthIncomplete(completeEntitlement)
            }
        }
        try await extend(bundleIds)
    }

    static func sendGrantedEvents(
        target: DocGoogleConnectTarget,
        eventWriter: any ConnectionEventWriterProtocol
    ) async throws {
        try await eventWriter.sendCloudGrantedEvents(
            providerIds: [providerId],
            capability: nil,
            grantedToInboxIds: target.agentInboxIds,
            in: target.connectionEventConversationId
        )
    }

    @MainActor
    private static func completeRetryingAuthIncomplete(
        _ complete: () async throws -> Void
    ) async throws {
        for delay in [Duration.seconds(1), .seconds(2)] {
            do {
                try await complete()
                return
            } catch AbilitiesAPI.EndpointError.authIncomplete {
                try await Task.sleep(for: delay)
            }
        }
        try await complete()
    }
}

extension DocExperienceViewModel {
    private func observeDmIfReady() async {
        guard let dmViewModel else {
            showGoogleConnectIfNeeded()
            return
        }
        if dmViewModel.conversation.id != observedDmConversationId {
            if !requiresAgentRecreationAfterFailure {
                agentStartupTimeoutTask?.cancel()
                agentStartupTimeoutTask = nil
                agentStartupState = .ready
                needsDeterministicAgentProvision = false
                hasRetriedRuntimeMismatch = false
            }
            observedDmConversationId = dmViewModel.conversation.id
        }
        refreshGoogleControlState()
        if let agentInboxId {
            requestControlResyncIfNeeded(agentInboxId: agentInboxId)
        }
        googleConnectTargetDidChange()
        showGoogleConnectIfNeeded()
        sendQueuedPhoneVerificationIfNeeded()
    }

    private func ensureDocAgentProvisioned(conversationId: String) async {
        for delay in DocAgentProvisionRetryPolicy.attemptDelays {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await session.ensureDefaultAgentConversationReady(id: conversationId)
            if agentInboxId != nil { return }
        }
    }

    private func validateDocRuntimeIfNeeded(conversationId: String) async -> Bool {
        guard FeatureFlags.shared.isDocModeEnabled else { return true }
        guard let selectedVariant = FeatureFlags.shared.selectedAgentVariant,
              selectedVariant.label == "Doc",
              let expectedVariantSlug = AgentVariantResolution.slug(for: conversationId),
              expectedVariantSlug == selectedVariant.slug else {
            failAgentStartup("Doc couldn't verify its preview runtime.", requiresRecreation: true)
            return false
        }
        let diagnostic = AgentJoinDiagnosticsStore.shared.diagnostic(for: conversationId)
        guard DocAgentConvergenceAction.resolve(
            conversationId: conversationId,
            diagnostic: diagnostic,
            expectedVariantSlug: expectedVariantSlug
        ) == .replace else {
            return true
        }

        let exhaustedAutomaticRetry = hasRetriedRuntimeMismatch
        await Self.tearDownAgentBinding(
            session: session,
            defaults: defaults,
            replayFirstRun: false,
            notify: false,
            additionalConversationId: conversationId
        )
        resetRuntimeState(preservingWelcome: true, invalidatesStartup: false)
        guard !exhaustedAutomaticRetry else {
            failAgentStartup(
                "Doc couldn't start on its preview runtime. Check Settings › Debug and try again.",
                requiresRecreation: true
            )
            return false
        }
        hasRetriedRuntimeMismatch = true
        await startAgentIfNeeded()
        return false
    }

    private func sendQueuedPhoneVerificationIfNeeded() {
        guard dmViewModel != nil,
              let number = queuedVerificationNumber,
              let text = DocControlRequestMessage.verifyRequestText(number: number) else {
            return
        }
        queuedVerificationNumber = nil
        performPhoneVerificationRequest(number: number, text: text)
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
        let action = DocAgentConvergenceAction.resolve(
            conversationId: storedId,
            diagnostic: diagnostic,
            expectedVariantSlug: variant.slug
        )
        guard action == .replace else {
            if let storedId {
                AgentVariantAssignmentStore.shared.assign(slug: variant.slug, to: storedId)
            }
            return DocModeConvergenceResult(
                conversationId: storedId,
                canStart: true,
                errorMessage: nil
            )
        }

        await Self.tearDownAgentBinding(
            session: session,
            defaults: defaults,
            replayFirstRun: false,
            notify: false,
            additionalConversationId: storedId
        )
        resetRuntimeState(preservingWelcome: true, invalidatesStartup: false)
        markAgentStartupProgress()
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
    ) async {
        await tearDownAgentBinding(
            session: session,
            defaults: defaults,
            replayFirstRun: true,
            notify: true,
            additionalConversationId: nil
        )
    }

    static func resetAgentBindingForVariantConvergence(
        session: any SessionManagerProtocol,
        defaults: UserDefaults = .standard
    ) async {
        await tearDownAgentBinding(
            session: session,
            defaults: defaults,
            replayFirstRun: false,
            notify: true,
            additionalConversationId: nil
        )
    }

    private static func tearDownAgentBinding(
        session: any SessionManagerProtocol,
        defaults: UserDefaults,
        replayFirstRun: Bool,
        notify: Bool,
        additionalConversationId: String?
    ) async {
        var conversationIds: [String] = []
        for conversationId in [
            storedOriginConversationId(session: session, defaults: defaults),
            additionalConversationId,
            session.peekPreparedConversationId(),
        ].compactMap({ $0 }) where !conversationIds.contains(conversationId) {
            conversationIds.append(conversationId)
        }
        for conversationId in conversationIds {
            await session.discardClaimedConversation(id: conversationId)
            AgentVariantAssignmentStore.shared.assign(slug: nil, to: conversationId)
            AgentJoinDiagnosticsStore.shared.clear(conversationId: conversationId)
        }
        clearAgentBindingStorage(
            session: session,
            defaults: defaults,
            replayFirstRun: replayFirstRun,
            notify: notify
        )
    }

    private static func clearAgentBindingStorage(
        session: any SessionManagerProtocol,
        defaults: UserDefaults,
        replayFirstRun: Bool,
        notify: Bool
    ) {
        var components = [
            "originConversationId",
            "googleConnectHandled",
            "snapshot",
            "state",
            "docLanes",
            controlComponent,
            controlAgentInboxIdComponent,
            controlResyncMarkerComponent,
        ]
        if replayFirstRun {
            components.append("welcome")
            components.append(verificationHelloComponent)
            components.append(verificationNumberComponent)
            components.append("firstRun")
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
            object: defaults,
            userInfo: [
                accountIdentifierUserInfoKey: accountIdentifier(session: session),
                preserveWelcomeUserInfoKey: !replayFirstRun,
            ]
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
        verificationHelloComponent,
        verificationNumberComponent,
        "firstRun",
        "originConversationId",
        "googleConnectHandled",
        "snapshot",
        "state",
        "docLanes",
        controlComponent,
        controlAgentInboxIdComponent,
        controlResyncMarkerComponent,
    ]
    private static let controlComponent: String = "control"
    private static let controlAgentInboxIdComponent: String = "controlAgentInboxId"
    private static let controlResyncMarkerComponent: String = "controlResyncSentAgentInboxId"
    private static let verificationHelloComponent: String = "verificationHello"
    private static let verificationNumberComponent: String = "verificationNumber"
    private static let provisionalAccountIdentifier: String = "registering"
    private static let accountIdentifierUserInfoKey: String = "accountIdentifier"
    private static let preserveWelcomeUserInfoKey: String = "preserveWelcome"

    private static func initialWelcomeCompletion(
        previewStage: DocPreviewStage?,
        defaults: UserDefaults,
        accountIdentifier: String
    ) -> Bool {
        guard previewStage != .welcome else { return false }
        return defaults.bool(forKey: storageKey("welcome", accountIdentifier: accountIdentifier))
    }

    private static func initialControlSnapshot(
        previewStage: DocPreviewStage?,
        defaults: UserDefaults,
        accountIdentifier: String
    ) -> DocControlSnapshot? {
        if let previewStage {
            switch previewStage {
            case .welcome, .verify, .verifyPreparing, .verifyStartupFailure, .verificationHello:
                return previewVerificationSnapshot
            case .verifyCode:
                return previewVerificationSentSnapshot
            case .verifyFallback:
                return previewVerificationFallbackSnapshot
            default:
                break
            }
        }
        guard let data = defaults.data(
            forKey: storageKey(controlComponent, accountIdentifier: accountIdentifier)
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(DocControlSnapshot.self, from: data)
    }

    private func restoreVerificationFlow() {
        guard let controlSnapshot else {
            verificationFlowState = .enteringNumber
            return
        }
        if let verified = controlSnapshot.verificationsByKey.values.first(where: { $0.status == .verified }) {
            verificationFlowState = .verified(number: verified.ownerNumber)
            return
        }

        if let request = controlSnapshot.verificationsByKey[DocControlMessage.verificationRequestKey],
           let number = request.ownerNumber {
            switch request.status {
            case .sent:
                verificationFlowState = .enteringCode(number: number, attemptFailed: false)
            case .sendFailed:
                verificationFlowState = .fallback(number: number)
            case .attemptFailed:
                verificationFlowState = .enteringCode(number: number, attemptFailed: true)
            case .pending, .verified, .expired, .released:
                verificationFlowState = .enteringNumber
            }
            return
        }
        verificationFlowState = .enteringNumber
    }

    private func storageKey(_ component: String) -> String {
        Self.storageKey(component, accountIdentifier: storageAccountIdentifier)
    }

    private var agentIsReadyForFirstRun: Bool {
        agentReadinessOverride ?? (dmViewModel != nil || agentStartupState == .ready)
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
        hasCompletedVerificationHello = defaults.bool(forKey: storageKey(Self.verificationHelloComponent))
        hasCompletedFirstRun = defaults.bool(forKey: storageKey("firstRun"))
        if let data = defaults.data(forKey: storageKey("docLanes")),
           let registry = try? JSONDecoder().decode(DocLaneRegistry.self, from: data) {
            docLaneRegistry = registry
        } else {
            docLaneRegistry = .init()
        }

        state = nil
        controlSnapshot = nil
        pendingItems = []
        docContentsById = [:]
        startingGroupConnectionDocIds = []
        resolvedItemIds = []
        itemsNeedingHistoryReconciliation = []
        compatibilityDetector = .init()
        if let data = defaults.data(forKey: storageKey(Self.controlComponent)) {
            controlSnapshot = try? JSONDecoder().decode(DocControlSnapshot.self, from: data)
        }
        refreshGoogleControlState()
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
        if controlSnapshot != nil {
            compatibilityDetector.hasSeenDocSentinel = true
        }
        restoreVerificationFlow()
        reconcileFirstRunCompletion()
    }

    private func markAgentStartupProgress(restartsFailedAttempt: Bool = false) {
        if case .failed = agentStartupState, !restartsFailedAttempt {
            return
        }
        agentStartupProgressRevision &+= 1
        agentStartupState = .preparing
        scheduleAgentStartupTimeout()
    }

    private func scheduleAgentStartupTimeout() {
        agentStartupTimeoutTask?.cancel()
        let scheduledProgressRevision = agentStartupProgressRevision
        agentStartupTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: DocAgentStartupTimeoutPolicy.deadline)
            guard !Task.isCancelled,
                  let self else {
                return
            }
            let startupWorkMadeProgress = agentStartupProgressRevision != scheduledProgressRevision
            guard DocAgentStartupTimeoutPolicy.shouldFail(
                dmIsReady: dmViewModel != nil,
                startupWorkMadeProgress: startupWorkMadeProgress
            ) else {
                if startupWorkMadeProgress {
                    scheduleAgentStartupTimeout()
                }
                return
            }
            failAgentStartup("Doc is taking too long to start. Try again.")
        }
    }

    private func failAgentStartup(
        _ message: String,
        requiresRecreation: Bool = false
    ) {
        agentStartupTimeoutTask?.cancel()
        agentStartupTimeoutTask = nil
        requiresAgentRecreationAfterFailure = requiresRecreation
        agentStartupState = .failed(message)
    }

    private func resetRuntimeState(
        preservingWelcome: Bool = false,
        invalidatesStartup: Bool = true
    ) {
        let lostGoogleConnect = googleConnectRequestId != nil || isFinishingGoogleConnect
        let completedWelcome = hasCompletedWelcome
        let completedVerificationHello = hasCompletedVerificationHello
        let completedFirstRun = hasCompletedFirstRun
        if invalidatesStartup {
            startupGeneration &+= 1
            agentStartupRequestRevision &+= 1
            isStartingAgent = false
        }
        conversationViewModel?.onCreationFailed = nil
        conversationViewModel?.onAgentProvisionFailed = nil
        conversationViewModel?.cleanUpIfNeeded()
        docMessageAggregator?.stop()
        docMessageAggregator = nil
        googleConnectTask?.cancel()
        googleConnectTask = nil
        googleConnectRequestId = nil
        cancelGoogleAcknowledgmentTimeout()
        observedDmConversationId = nil
        observedDocAgentInboxId = nil
        conversationViewModel = nil
        agentDmSession = nil
        state = nil
        controlSnapshot = nil
        pendingItems = []
        docContentsById = [:]
        docContentLoadStates = [:]
        answerDeliveryTimeoutTasks.values.forEach { $0.cancel() }
        answerDeliveryTimeoutTasks = [:]
        itemSendStates = [:]
        composerTexts = [:]
        composerPhotos = [:]
        pendingScreenshotCount = 0
        startingGroupConnectionDocIds = []
        isGoogleStatusLoaded = false
        isGoogleDocsReady = false
        isConnectingGoogleDocs = false
        isGoogleConnectQueued = false
        googleConnectErrorMessage = lostGoogleConnect ? "Lost the chat connection. Try again." : nil
        verificationFlowState = .enteringNumber
        verificationTransportErrorMessage = nil
        cancelVerificationAcknowledgmentTimeout()
        queuedVerificationNumber = nil
        needsDeterministicAgentProvision = false
        requiresAgentRecreationAfterFailure = false
        isPresentingGoogleConnect = false
        isPresentingHistory = false
        isPresentingShareNumber = false
        isPresentingShareDoc = false
        presentedDraftItem = nil
        presentedDraftComposerScope = nil
        activeAnswerItemId = nil
        composerFocusRequest = nil
        sharedDocNumber = nil
        sharedNumberDocName = nil
        sharedDocText = nil
        docLaneProvisionTasks.values.forEach { $0.cancel() }
        docLaneProvisionTasks = [:]
        docLaneViewModels = [:]
        docLaneRegistry = .init()
        agentStartupTimeoutTask?.cancel()
        agentStartupTimeoutTask = nil
        agentStartupState = .idle
        agentJoinDiagnostic = nil
        hasObservedControlEvent = false
        isControlResyncInFlight = false
        hasCompletedWelcome = preservingWelcome ? completedWelcome : false
        hasCompletedVerificationHello = preservingWelcome ? completedVerificationHello : false
        hasCompletedFirstRun = preservingWelcome ? completedFirstRun : false
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
    enum Sender {
        case currentUser
        case agent
    }

    fileprivate(set) var hasSeenDocSentinel: Bool = false
    private var ordinarySourcePositions: Set<DocMessagePosition> = []
    private var normalAgentMessagePositions: Set<DocMessagePosition> = []

    var shouldWarn: Bool {
        guard !hasSeenDocSentinel,
              let firstAgentMessage = normalAgentMessagePositions.min(),
              let sourceMessage = ordinarySourcePositions
              .filter({ $0 > firstAgentMessage })
              .min(),
              let latestAgentMessage = normalAgentMessagePositions.max() else {
            return false
        }
        return latestAgentMessage > sourceMessage
    }

    @discardableResult
    mutating func observe(
        text: String,
        sender: Sender,
        position: DocMessagePosition
    ) -> Bool {
        let oldValue = self
        switch sender {
        case .agent:
            if DocStateMessage.isDataPlaneText(text) {
                hasSeenDocSentinel = true
            } else if !DocWireMessage.isHiddenText(text) {
                normalAgentMessagePositions.insert(position)
            }
        case .currentUser:
            if !DocWireMessage.isHiddenText(text) {
                ordinarySourcePositions.insert(position)
            }
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
