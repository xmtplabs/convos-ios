import Combine
import ConvosCore
import ConvosInvites
import SwiftUI

// MARK: - Error Types

struct IdentifiableError: Identifiable {
    let id: UUID = UUID()
    let title: String
    let description: String
    let retryAction: RetryAction?

    init(title: String, description: String, retryAction: RetryAction? = nil) {
        self.title = title
        self.description = description
        self.retryAction = retryAction
    }

    init(error: DisplayError, retryAction: RetryAction? = nil) {
        self.title = error.title
        self.description = error.description
        self.retryAction = retryAction ?? (error as? RetryableDisplayError)?.retryAction
    }
}

enum NewConversationMode {
    case newConversation
    case newAgent
    /// Same flow as `.newConversation`: placeholder VM up front, real VM
    /// swapped in at `.ready`. The create sequence inside
    /// `ConversationStateMachine` additionally folds in
    /// `ConversationMetadataWriter.addMembers(_:to:)` for the supplied
    /// inbox IDs before emitting `.ready`. Used by the contacts picker
    /// "Start Conversation" path so navigation feels instant and the
    /// conversation arrives at `.ready` with the picked members already
    /// in it. `initialAgentTemplateIds` (defaults to empty) requests one
    /// fresh instance per id once the conversation reaches `.ready`,
    /// mirroring the single-template `.newConversationWithTemplate` flow.
    case newConversationWithMembers(
        initialMemberInboxIds: [String],
        initialAgentTemplateIds: [String] = []
    )
    /// Opens an existing conversation in the same sheet presentation we
    /// use for the new-convo flows. Used when "Chat" on a contact card
    /// resolves to a 1:1 the user already has with that person, so the
    /// app doesn't let them spin up a second redundant 1:1. The state
    /// machine uses `.useExisting` (no create, no addMembers), and the
    /// conversation publisher emits `.ready` against the existing row.
    case existingConversation(conversationId: String)
    /// Same instant-placeholder flow as `.newConversation`; once the
    /// conversation reaches `.ready`, a fresh instance of the given
    /// agent template is requested into it. Used by the agent-template
    /// deeplink (`convos://template/<id>`).
    case newConversationWithTemplate(templateId: String)
    case scanner
    case joinInvite(code: String)
}

@MainActor
@Observable
class NewConversationViewModel: Identifiable {
    // MARK: - Public

    let session: any SessionManagerProtocol
    private(set) var conversationViewModel: ConversationViewModel? {
        didSet {
            conversationViewModel?.allowsContactCard = !suppressesContactCard
            conversationViewModel?.isInAgentBuilderFlow = isInAgentBuilderFlow
        }
    }
    /// When `true`, every `conversationViewModel` we vend (the initial
    /// placeholder, and any replacement created by
    /// `configureWithMessagingService`) has its `allowsContactCard` set to
    /// `false`. The Agent Builder flips this on so the contact card stays
    /// hidden during the entire builder lifetime — including across the
    /// inbox-acquisition VM swap — and only flips back to visible after the
    /// post-Make reveal delay. Regular `NewConversationViewModel` callers
    /// leave this `false` so the card shows normally.
    var suppressesContactCard: Bool = false {
        didSet {
            guard oldValue != suppressesContactCard else { return }
            conversationViewModel?.allowsContactCard = !suppressesContactCard
        }
    }
    /// Mirrors `ConversationViewModel.isInAgentBuilderFlow` at the wrapper
    /// level so the value survives the inbox-acquisition VM swap. The
    /// Agent Builder sets this on appear and clears it on disappear; the
    /// `didSet` on `conversationViewModel` forwards it onto the current inner
    /// VM, which in turn forwards it onto the messages-list repo so the
    /// processor can suppress the "Agent joined" update row for the
    /// duration of the builder UI.
    var isInAgentBuilderFlow: Bool = false {
        didSet {
            guard oldValue != isInAgentBuilderFlow else { return }
            conversationViewModel?.isInAgentBuilderFlow = isInAgentBuilderFlow
        }
    }
    let qrScannerViewModel: QRScannerViewModel
    private(set) var messagesTopBarTrailingItem: MessagesViewTopBarTrailingItem = .share
    private(set) var messagesTopBarTrailingItemEnabled: Bool = false
    private(set) var messagesTextFieldEnabled: Bool = false
    private let startedWithFullscreenScanner: Bool
    /// True when this VM was created with `.newConversationWithMembers`
    /// (i.e. the contacts picker started the convo). Drives
    /// `ConversationViewModel.hidesInviteCard` so the QR header isn't
    /// rendered on top of a chat that already has members.
    private let startedWithSeededMembers: Bool
    /// True when this VM was constructed with `.existingConversation`.
    /// Belt-and-braces guard against `cleanUpIfNeeded` ever destroying
    /// the real conversation behind the sheet - see comment there.
    private let isExistingConversation: Bool
    /// Captured initial-member inbox ids for the seeded-members flow.
    /// Used to seed each draft `Conversation` with contact-derived
    /// members so the chat header renders the contact's name and
    /// avatar from the moment the sheet opens, instead of flickering
    /// through "New Convo" while the state machine creates the real
    /// group.
    private let seededMemberInboxIds: [String]
    let allowsDismissingScanner: Bool
    private let autoCreateConversation: Bool
    private(set) var showingFullScreenScanner: Bool
    var presentingJoinConversationSheet: Bool = false
    var displayError: IdentifiableError? {
        didSet {
            qrScannerViewModel.presentingInvalidInviteSheet = displayError != nil
            if oldValue != nil && displayError == nil {
                qrScannerViewModel.resetScanTimer()
                qrScannerViewModel.resetScanning()
                guard let conversationStateManager else { return }
                resetTask?.cancel()
                resetTask = Task { [conversationStateManager] in
                    await conversationStateManager.resetFromError()
                }
            }
        }
    }

    /// The id returned by `session.prepareNewConversation()` when this VM
    /// claimed a row from the unused-conversation cache, or `nil` if the
    /// pool was empty (and the state machine created one on demand). Kept
    /// here so wrapping VMs (e.g. `AgentBuilderViewModel`) can call
    /// `session.commitClaimedConversation(id:)` at their own commit
    /// moment without re-deriving the id from the draft-vs-real
    /// `conversationViewModel.conversation.id`.
    private(set) var claimedConversationId: String?

    private(set) var isCreatingConversation: Bool = false
    private(set) var currentError: Error?
    private(set) var conversationState: ConversationStateMachine.State = .uninitialized {
        didSet {
            switch conversationState {
            case .ready:
                let firedAlready = _reachedReadyState
                _reachedReadyState = true
                if !firedAlready { onReachedReady?() }
            case .joining:
                _reachedJoiningState = true
            default:
                break
            }
        }
    }

    /// Fires exactly once when the state machine first reaches `.ready`.
    /// Wrappers (e.g. `AgentBuilderViewModel`) use this to kick off
    /// follow-on work like inviting an agent once the conversation
    /// has an invite slug.
    var onReachedReady: (() -> Void)?
    private var cachedInviteCode: String?
    private var consecutiveFailureCount: Int = 0

    // MARK: - Private

    private var conversationStateManager: (any ConversationStateManagerProtocol)?
    private var acquiredMessagingService: AnyMessagingService?
    /// Agent template ids to provision into the conversation once it
    /// reaches `.ready`. Populated for the `.newConversationWithTemplate`
    /// deeplink mode, the `convos://template/<id>` QR scan path, and the
    /// contacts picker's mixed humans+templates new-conversation flow.
    /// One entry per fresh instance to spawn; empty for the human-only
    /// path.
    @ObservationIgnored
    private var pendingAgentTemplateIds: [String] = []
    /// Set when a template QR is scanned before the messaging service
    /// (and `conversationStateManager`) has been acquired; the create is
    /// kicked off once configuration completes. Mirrors `pendingInviteCode`.
    @ObservationIgnored
    private var pendingAgentTemplateCreate: Bool = false
    /// One-shot guard so a re-emitted `.ready` state doesn't request the
    /// agent join twice.
    @ObservationIgnored
    private var didTriggerAgentJoin: Bool = false
    @ObservationIgnored
    nonisolated(unsafe) private var _reachedReadyState: Bool = false
    @ObservationIgnored
    nonisolated(unsafe) private var _reachedJoiningState: Bool = false
    @ObservationIgnored
    private var _cleanedUp: Bool = false
    @ObservationIgnored
    private var inboxAcquisitionTask: Task<Void, Never>?
    @ObservationIgnored
    private var newConversationTask: Task<Void, Error>?
    @ObservationIgnored
    private var joinConversationTask: Task<Void, Error>?
    @ObservationIgnored
    private var resetTask: Task<Void, Never>?
    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored
    private var stateObservationTask: Task<Void, Never>?
    @ObservationIgnored
    private var dismissAction: DismissAction?
    private var pendingInviteCode: String?
    private let perfStartTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    // MARK: - Init

    init(
        session: any SessionManagerProtocol,
        mode: NewConversationMode
    ) {
        self.session = session
        self.qrScannerViewModel = QRScannerViewModel()

        switch mode {
        case .newConversationWithTemplate(let templateId):
            self.pendingAgentTemplateIds = [templateId]
        case .newConversationWithMembers(_, let templateIds):
            self.pendingAgentTemplateIds = templateIds
        default:
            break
        }

        switch mode {
        case .newConversation, .newAgent, .newConversationWithMembers, .newConversationWithTemplate:
            self.autoCreateConversation = true
            self.startedWithFullscreenScanner = false
            self.showingFullScreenScanner = false
            self.allowsDismissingScanner = true

        case .scanner:
            self.autoCreateConversation = false
            self.startedWithFullscreenScanner = true
            self.showingFullScreenScanner = true
            self.allowsDismissingScanner = true

        // `.existingConversation` and `.joinInvite` both open / join
        // an existing chat without creating one - same scanner-off
        // configuration.
        case .existingConversation, .joinInvite:
            self.autoCreateConversation = false
            self.startedWithFullscreenScanner = false
            self.showingFullScreenScanner = false
            self.allowsDismissingScanner = true
        }

        if case .newConversationWithMembers(let ids, _) = mode {
            self.startedWithSeededMembers = true
            self.seededMemberInboxIds = ids
        } else {
            self.startedWithSeededMembers = false
            self.seededMemberInboxIds = []
        }

        self.isExistingConversation = if case .existingConversation = mode { true } else { false }

        self.isCreatingConversation = mode.isNewConversation
        createPlaceholderConversationViewModel()
        acquireInbox(mode: mode)
    }

    internal init(
        session: any SessionManagerProtocol,
        messagingService: AnyMessagingService,
        existingConversationId: String? = nil,
        autoCreateConversation: Bool = false,
        showingFullScreenScanner: Bool = false,
        allowsDismissingScanner: Bool = true,
    ) {
        self.session = session
        self.qrScannerViewModel = QRScannerViewModel()
        self.autoCreateConversation = autoCreateConversation
        self.startedWithFullscreenScanner = showingFullScreenScanner
        self.startedWithSeededMembers = false
        self.seededMemberInboxIds = []
        // Tests-only init - the warm-cache flow goes through the
        // public init. Existing-conversation cleanup guard stays off.
        self.isExistingConversation = false
        self.showingFullScreenScanner = showingFullScreenScanner
        self.allowsDismissingScanner = allowsDismissingScanner

        configureWithMessagingService(
            messagingService,
            existingConversationId: existingConversationId
        )
    }

    deinit {
        Log.info("deinit")
        inboxAcquisitionTask?.cancel()
        newConversationTask?.cancel()
        joinConversationTask?.cancel()
        resetTask?.cancel()
        stateObservationTask?.cancel()
    }

    func cleanUpIfNeeded() {
        guard !_reachedReadyState, !_reachedJoiningState, !_cleanedUp else { return }
        // Defensive: `.existingConversation` flows should already exit
        // via `_reachedReadyState` (useExisting emits .ready). If that
        // ever drifts and `deleteConversation` stops being a no-op,
        // this prevents destroying the real conversation behind the
        // sheet on dismiss-before-ready.
        guard !isExistingConversation else { return }
        _cleanedUp = true
        deleteConversation()
    }

    // MARK: - Inbox Acquisition

    private func acquireInbox(mode: NewConversationMode) {
        inboxAcquisitionTask?.cancel()
        inboxAcquisitionTask = Task { [weak self] in
            guard let self else { return }

            switch mode {
            case .newConversation, .newAgent, .newConversationWithTemplate:
                let (messagingService, existingConversationId) = await session.prepareNewConversation()
                guard !Task.isCancelled else { return }
                let inboxElapsed = (CFAbsoluteTimeGetCurrent() - perfStartTime) * 1000
                Log.info("[PERF] NewConversation.inboxAcquired: \(String(format: "%.0f", inboxElapsed))ms")
                claimedConversationId = existingConversationId
                // `.newAgent` defers commit until the user actually taps Make
                // in the Agent Builder (`AgentBuilderViewModel.commit`) so the
                // claimed cache row stays hidden from the chats list during
                // compose. The other modes drop straight into a chat composer
                // — committing here mirrors the previous behavior of making
                // the conversation visible the moment it's claimed.
                let shouldCommitNow: Bool
                switch mode {
                case .newAgent:
                    shouldCommitNow = false
                default:
                    shouldCommitNow = true
                }
                if shouldCommitNow, let existingConversationId {
                    await session.commitClaimedConversation(id: existingConversationId)
                }
                configureWithMessagingService(
                    messagingService,
                    existingConversationId: existingConversationId
                )

            case .newConversationWithMembers(let initialMemberInboxIds, _):
                let (messagingService, existingConversationId) = await session.prepareNewConversation()
                guard !Task.isCancelled else { return }
                let inboxElapsed = (CFAbsoluteTimeGetCurrent() - perfStartTime) * 1000
                Log.info("[PERF] NewConversation.inboxAcquired: \(String(format: "%.0f", inboxElapsed))ms")
                claimedConversationId = existingConversationId
                if let existingConversationId {
                    await session.commitClaimedConversation(id: existingConversationId)
                }
                configureWithMessagingService(
                    messagingService,
                    existingConversationId: existingConversationId,
                    initialMemberInboxIds: initialMemberInboxIds
                )

            case .existingConversation(let conversationId):
                configureWithMessagingService(session.messagingService(), existingConversationId: conversationId)

            case .scanner, .joinInvite:
                let messagingService = session.messagingService()
                guard !Task.isCancelled else { return }
                let inboxElapsed = (CFAbsoluteTimeGetCurrent() - perfStartTime) * 1000
                Log.info("[PERF] NewConversation.inboxAcquired: \(String(format: "%.0f", inboxElapsed))ms")
                configureWithMessagingService(messagingService, existingConversationId: nil)
            }

            if case .joinInvite(let code) = mode {
                joinConversation(inviteCode: code)
            }
        }
    }

    private func createPlaceholderConversationViewModel() {
        let draftId: String = "draft-\(UUID().uuidString)"
        let draftConversation: Conversation = makeDraftConversation(id: draftId)
        let messagesRepo = MockMessagesRepository(conversationId: draftId)
        let draftRepo = MockDraftConversationRepository(conversation: draftConversation, messagesRepository: messagesRepo)
        let stateManager = MockConversationStateManager(
            conversationId: draftId,
            draftConversationRepository: draftRepo
        )
        let mockService = MockMessagingService(conversationStateManager: stateManager)
        let convoVM = ConversationViewModel(
            conversation: draftConversation,
            session: session,
            messagingService: mockService,
            conversationStateManager: stateManager,
            applyGlobalDefaultsForNewConversation: false
        )
        convoVM.showsInfoView = !startedWithFullscreenScanner
        convoVM.allowsContactCard = !suppressesContactCard
        armSeededExpectationIfNeeded(on: convoVM, for: draftConversation)
        self.conversationViewModel = convoVM
    }

    /// Returns a draft `Conversation` for use as a placeholder. When this
    /// VM was started by the contacts picker
    /// (`startedWithSeededMembers == true`), the draft carries synthetic
    /// `ConversationMember`s built from the contact list so the chat
    /// header renders the contact's name + avatar (and `kind = .dm` for
    /// a single contact) from the moment the sheet opens. The
    /// conversation publisher's `.ready` emission later replaces the
    /// synthetic members with the real ones keyed by the same `inboxId`,
    /// so the transition is a no-op re-render rather than a flicker.
    /// Arms the `ConversationViewModel` publisher-emission gate for
    /// picker-seeded VMs only. The default state on
    /// `ConversationViewModel` is "gate open"; arming here matches
    /// the synthetic draft we just constructed so DB emissions with
    /// fewer non-self members are dropped until the state machine's
    /// addMembers hook catches up. No-op when the draft has no seeded
    /// members (e.g. `.newConversation`, scanner, joinInvite).
    private func armSeededExpectationIfNeeded(
        on convoVM: ConversationViewModel,
        for draftConversation: Conversation
    ) {
        guard startedWithSeededMembers else { return }
        convoVM.markSeeded(expectingMemberCount: draftConversation.membersWithoutCurrent.count)
    }

    private func makeDraftConversation(id: String) -> Conversation {
        guard startedWithSeededMembers, !seededMemberInboxIds.isEmpty else {
            return .empty(id: id)
        }
        let contactsRepository = session.messagingServiceSync().contactsRepository()
        let seededContacts: [Contact] = seededMemberInboxIds.compactMap { contactsRepository.contact(for: $0) }
        guard !seededContacts.isEmpty else {
            return .empty(id: id)
        }
        var members: [ConversationMember] = seededContacts.map { $0.syntheticMember(conversationId: id) }
        if case .authorized(let selfInboxId) = session.messagingServiceSync().state {
            let selfProfile = Profile(
                inboxId: selfInboxId,
                conversationId: id,
                name: nil,
                avatar: nil
            )
            members.insert(
                ConversationMember(profile: selfProfile, role: .superAdmin, isCurrentUser: true),
                at: 0
            )
        }
        return .draft(id: id, seededMembers: members)
    }

    private func configureWithMessagingService(
        _ messagingService: AnyMessagingService,
        existingConversationId: String?,
        initialMemberInboxIds: [String] = []
    ) {
        // Warm-cache id preservation. When `prepareNewConversation()`
        // hands back an `existingConversationId` (a warm-cached, already-
        // published XMTP group from `UnusedConversationCache`), we must
        // route through `conversationStateManager(for:)` so the state
        // machine resumes via `useExisting` instead of publishing a
        // second group via `create`. The autoCreate branch below
        // explicitly guards on `existingConversationId == nil` to enforce
        // this.
        let stateManager: any ConversationStateManagerProtocol
        if let existingConversationId {
            stateManager = messagingService.conversationStateManager(
                for: existingConversationId,
                initialMemberInboxIds: initialMemberInboxIds
            )
        } else {
            stateManager = messagingService.conversationStateManager(
                initialMemberInboxIds: initialMemberInboxIds
            )
        }
        self.conversationStateManager = stateManager
        self.acquiredMessagingService = messagingService
        let draftConversation: Conversation = makeDraftConversation(
            id: stateManager.draftConversationRepository.conversationId
        )
        let convoVM = ConversationViewModel(
            conversation: draftConversation,
            session: session,
            messagingService: messagingService,
            conversationStateManager: stateManager,
            applyGlobalDefaultsForNewConversation: autoCreateConversation
        )
        if startedWithFullscreenScanner {
            convoVM.showsInfoView = false
        }
        convoVM.allowsContactCard = !suppressesContactCard
        armSeededExpectationIfNeeded(on: convoVM, for: draftConversation)
        self.conversationViewModel = convoVM
        setupObservations()
        setupStateObservation()

        if let pendingCode = pendingInviteCode {
            pendingInviteCode = nil
            joinConversation(inviteCode: pendingCode)
        }

        if pendingAgentTemplateCreate {
            pendingAgentTemplateCreate = false
            createConversationForAgentTemplate()
        }

        if autoCreateConversation && existingConversationId == nil {
            newConversationTask = Task { [weak self, stateManager] in
                guard self != nil else { return }
                guard !Task.isCancelled else { return }
                do {
                    try await stateManager.createConversation()
                    await self?.applyGlobalConversationDefaultsIfNeeded(using: stateManager)
                    await self?.persistHidesInviteCardIfNeeded(stateManager: stateManager)
                } catch {
                    Log.error("Error auto-creating conversation: \(error.localizedDescription)")
                    guard !Task.isCancelled else { return }
                    await MainActor.run { [weak self] in
                        self?.handleCreationError(error)
                    }
                }
            }
        } else if existingConversationId != nil {
            // Warm-cached convo: the DB row already exists, so the flag
            // can be persisted right away without waiting on create.
            Task { [weak self, stateManager] in
                await self?.persistHidesInviteCardIfNeeded(stateManager: stateManager)
            }
        }
    }

    /// Persist `hidesInviteCard = true` on the conversation's local state
    /// when this VM was launched via the contacts picker
    /// (`.newConversationWithMembers`). Survives navigating away and
    /// re-opening the chat from the conversations list.
    private func persistHidesInviteCardIfNeeded(
        stateManager: any ConversationStateManagerProtocol
    ) async {
        guard startedWithSeededMembers else { return }
        let conversationId = stateManager.draftConversationRepository.conversationId
        do {
            try await stateManager.conversationLocalStateWriter.setHidesInviteCard(true, for: conversationId)
        } catch {
            Log.error("Failed to persist hidesInviteCard for \(conversationId): \(error.localizedDescription)")
        }
    }

    // MARK: - Actions

    func onScanInviteCode() {
        presentingJoinConversationSheet = true
    }

    /// Routes a scanned QR payload. A `convos://template/<id>` code
    /// pivots the scanner into the agent-template spawn flow; anything
    /// else is treated as a conversation invite, exactly as before.
    func handleScannedCode(_ code: String) {
        if let url = URL(string: code), let templateId = DeepLinkHandler.agentTemplateId(from: url) {
            startAgentTemplateConversation(templateId: templateId)
        } else {
            joinConversation(inviteCode: code)
        }
    }

    /// Pivots a scanner-mode flow into the agent-template spawn path when
    /// the user scans a template QR. Mirrors the
    /// `.newConversationWithTemplate` deeplink mode: create a fresh
    /// conversation, then request an instance of the template into it
    /// once it reaches `.ready` (handled in `handleStateChange`).
    private func startAgentTemplateConversation(templateId: String) {
        pendingAgentTemplateIds = [templateId]
        showingFullScreenScanner = false
        isCreatingConversation = true

        guard conversationStateManager != nil else {
            pendingAgentTemplateCreate = true
            return
        }
        createConversationForAgentTemplate()
    }

    private func createConversationForAgentTemplate() {
        guard let conversationStateManager else { return }
        newConversationTask?.cancel()
        newConversationTask = Task { [weak self, conversationStateManager] in
            guard self != nil else { return }
            guard !Task.isCancelled else { return }
            do {
                try await conversationStateManager.createConversation()
                await self?.applyGlobalConversationDefaultsIfNeeded(using: conversationStateManager)
            } catch {
                Log.error("Error creating conversation for agent template: \(error.localizedDescription)")
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.handleCreationError(error)
                }
            }
        }
    }

    func joinConversation(inviteCode: String) {
        cachedInviteCode = inviteCode

        guard let conversationStateManager else {
            pendingInviteCode = inviteCode
            return
        }

        joinConversationTask?.cancel()
        joinConversationTask = Task { [weak self, conversationStateManager] in
            guard self != nil else { return }
            guard !Task.isCancelled else { return }
            do {
                try await conversationStateManager.joinConversation(inviteCode: inviteCode)
                await self?.applyGlobalConversationDefaultsIfNeeded(using: conversationStateManager)
                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    self?.handleJoinSuccess()
                }
            } catch {
                Log.error("Error joining new conversation: \(error.localizedDescription)")
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.handleJoinError(error)
                }
            }
        }
    }

    /// Send a first message through the state machine. Used by wrapping
    /// flows (e.g. AgentBuilderViewModel) that commit a draft before
    /// the user sees the chat view. If the state machine hasn't reached
    /// `.ready` yet, the existing message-stream queue inside
    /// `ConversationStateMachine.sendMessage` holds the send until it does.
    func send(text: String) async throws {
        guard let conversationStateManager else {
            throw ConversationStateMachineError.noConversationStateManager
        }
        try await conversationStateManager.send(text: text)
    }

    func deleteConversation() {
        Log.info("Deleting conversation")
        newConversationTask?.cancel()
        joinConversationTask?.cancel()
        // Drop the conversation row claimed via `prepareNewConversation()`
        // when the user backs out without engaging. Key off
        // `claimedConversationId` so existing-conversation flows
        // (`.existingConversation(...)`) don't accidentally delete the
        // user's real conversation. The single-inbox refactor turned the
        // old per-conversation `session.deleteInbox` cleanup into a no-op
        // (it would destroy the user's account), so without this the
        // warm-cached group would persist in the conversations list.
        // Drafts skip — they don't have a visible row.
        if let claimedId = claimedConversationId {
            Task { [session] in
                await session.discardClaimedConversation(id: claimedId)
            }
        }
    }

    func setDismissAction(_ action: DismissAction) {
        dismissAction = action
    }

    func dismissWithDeletion() {
        _cleanedUp = true
        displayError = nil
        currentError = nil
        isCreatingConversation = false
        conversationViewModel?.isWaitingForInviteAcceptance = false
        inboxAcquisitionTask?.cancel()
        deleteConversation()
        dismissAction?()
    }

    func retryAction(_ action: RetryAction) {
        displayError = nil
        let delay = retryDelay
        switch action {
        case .createConversation:
            guard let conversationStateManager else { return }
            newConversationTask?.cancel()
            newConversationTask = Task { [weak self, conversationStateManager] in
                guard self != nil else { return }
                guard !Task.isCancelled else { return }
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                }
                do {
                    try await conversationStateManager.createConversation()
                    await self?.applyGlobalConversationDefaultsIfNeeded(using: conversationStateManager)
                } catch {
                    Log.error("Error retrying conversation creation: \(error.localizedDescription)")
                    guard !Task.isCancelled else { return }
                    await MainActor.run { [weak self] in
                        self?.handleCreationError(error)
                    }
                }
            }
        case .joinConversation(let inviteCode):
            if delay > 0 {
                joinConversationTask?.cancel()
                joinConversationTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { [weak self] in
                        self?.joinConversation(inviteCode: inviteCode)
                    }
                }
            } else {
                joinConversation(inviteCode: inviteCode)
            }
        }
    }

    private var retryDelay: TimeInterval {
        switch consecutiveFailureCount {
        case 0: return 0
        case 1: return Constant.retryDelayShort
        case 2: return Constant.retryDelayMedium
        default: return Constant.retryDelayMax
        }
    }

    // MARK: - Private

    @MainActor
    private func handleJoinSuccess() {
        presentingJoinConversationSheet = false
        displayError = nil
    }

    @MainActor
    private func handleJoinError(_ error: Error) {
        withAnimation {
            qrScannerViewModel.resetScanning()

            if startedWithFullscreenScanner {
                showingFullScreenScanner = true
            }

            displayError = (error as? DisplayError).map { IdentifiableError(error: $0) }
                ?? IdentifiableError(title: "Failed joining", description: "Please try again.")
        }
    }

    @MainActor
    private func handleCreationError(_ error: Error) {
        currentError = error
        isCreatingConversation = false
    }

    @MainActor
    private func resetUIState() {
        messagesTopBarTrailingItem = .share
        messagesTopBarTrailingItemEnabled = false
        messagesTextFieldEnabled = false
        conversationViewModel?.isWaitingForInviteAcceptance = false
        isCreatingConversation = false
        currentError = nil
        qrScannerViewModel.resetScanning()

        if startedWithFullscreenScanner {
            conversationViewModel?.showsInfoView = false
        } else {
            conversationViewModel?.showsInfoView = true
        }
    }

    private func setupObservations() {
        cancellables.removeAll()

        guard let conversationStateManager else { return }

        conversationStateManager.conversationIdPublisher
            .receive(on: DispatchQueue.main)
            .sink { conversationId in
                Log.info("Active conversation changed: \(conversationId)")
                NotificationCenter.default.post(
                    name: .activeConversationChanged,
                    object: nil,
                    userInfo: ["conversationId": conversationId as Any]
                )
            }
            .store(in: &cancellables)

        Publishers.Merge(
            conversationStateManager.sentMessage.map { _ in () },
            conversationStateManager.draftConversationRepository.messagesRepository
                .messagesPublisher
                .filter { $0.contains { $0.content.showsInMessagesList } }
                .map { _ in () }
        )
        .eraseToAnyPublisher()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            guard let self else { return }
            guard conversationState.isReadyOrJoining else { return }
            messagesTopBarTrailingItem = .share
        }
        .store(in: &cancellables)
    }

    private enum Constant {
        static let retryDelayShort: TimeInterval = 2
        static let retryDelayMedium: TimeInterval = 4
        static let retryDelayMax: TimeInterval = 8
    }
}

// MARK: - State observation and error handling

/// `ConversationStateMachine` observation, the per-state UI handling, and
/// the join / create error paths. Split into an extension purely to keep
/// the type body within SwiftLint's `type_body_length` budget; every
/// member stays file-private and `@MainActor`-isolated (inherited from
/// the type), so behavior is identical to when these lived inline.
extension NewConversationViewModel {
    @MainActor
    private func setupStateObservation() {
        guard let conversationStateManager else { return }
        stateObservationTask?.cancel()
        stateObservationTask = Task { [weak self, conversationStateManager] in
            for await state in conversationStateManager.stateSequence {
                guard let self else { break }
                self.handleStateChange(state)
                if Task.isCancelled { break }
            }
        }
    }

    @MainActor
    private func handleStateChange(_ state: ConversationStateMachine.State) {
        conversationState = state

        switch state {
        case .uninitialized:
            resetUIState()

        case .creating:
            let creatingElapsed = (CFAbsoluteTimeGetCurrent() - perfStartTime) * 1000
            Log.info("[PERF] NewConversation.creating: \(String(format: "%.0f", creatingElapsed))ms")
            isCreatingConversation = true
            conversationViewModel?.isWaitingForInviteAcceptance = false
            currentError = nil

        case .validating(let inviteCode):
            cachedInviteCode = inviteCode
            conversationViewModel?.isWaitingForInviteAcceptance = false
            isCreatingConversation = false
            currentError = nil

        case .validated(let invite, _, _, _):
            cachedInviteCode = try? invite.toURLSafeSlug()
            conversationViewModel?.isWaitingForInviteAcceptance = false
            isCreatingConversation = false
            currentError = nil
            showingFullScreenScanner = false

        case .joining(let invite, _):
            cachedInviteCode = try? invite.toURLSafeSlug()
            conversationViewModel?.isWaitingForInviteAcceptance = true
            conversationViewModel?.showsInfoView = true
            messagesTopBarTrailingItemEnabled = false
            messagesTopBarTrailingItem = .share
            messagesTextFieldEnabled = false
            isCreatingConversation = false
            currentError = nil

            conversationViewModel?.startOnboarding()
            Log.info("Waiting for invite acceptance...")

        case .ready(let result):
            consecutiveFailureCount = 0
            conversationViewModel?.startOnboarding()

            if result.origin == .joined {
                conversationViewModel?.inviteWasAccepted()
            } else {
                conversationViewModel?.isWaitingForInviteAcceptance = false
            }

            conversationViewModel?.showsInfoView = true
            messagesTopBarTrailingItemEnabled = true
            messagesTextFieldEnabled = true
            isCreatingConversation = false
            showingFullScreenScanner = false
            currentError = nil

            let readyElapsed = (CFAbsoluteTimeGetCurrent() - perfStartTime) * 1000
            Log.info("[PERF] NewConversation.ready: \(String(format: "%.0f", readyElapsed))ms (origin: \(result.origin))")
            Log.info("Conversation ready!")

            // Agent-template spawn: the conversation now exists with a
            // shareable invite, so request a fresh instance for each
            // pending templateId. Uses the batched fan-out method so all
            // N joins fire in parallel -- the single-flight
            // `requestAgentJoin(templateId:)` would cancel each prior
            // call as the loop advances, leaving only the last to land.
            // One-shot - `.ready` may re-emit.
            if !pendingAgentTemplateIds.isEmpty, !didTriggerAgentJoin {
                didTriggerAgentJoin = true
                conversationViewModel?.requestAgentJoins(templateIds: pendingAgentTemplateIds)
            }

        case .joinFailed(_, let error):
            consecutiveFailureCount += 1
            handleJoinFailedState(error)

        case .error(let error):
            consecutiveFailureCount += 1
            handleErrorState(error)
        }
    }

    private func applyGlobalConversationDefaultsIfNeeded(using stateManager: any ConversationStateManagerProtocol) async {
        let conversationId: String = stateManager.conversationId
        guard !conversationId.isEmpty else { return }

        do {
            try await session.photoPreferencesWriter().setAutoReveal(GlobalConvoDefaults.shared.autoRevealPhotos, for: conversationId)
        } catch {
            Log.error("Error applying global auto reveal preference: \(error)")
        }

        // The include-info default applies to every conversation this VM
        // creates - the auto-create modes and the scanned-template path
        // (which seeds `pendingAgentTemplateIds` but is not an auto-create
        // mode). It does not apply when joining an existing invite.
        guard autoCreateConversation || !pendingAgentTemplateIds.isEmpty else { return }

        do {
            try await stateManager.conversationMetadataWriter.updateIncludeInfoInPublicPreview(
                GlobalConvoDefaults.shared.includeInfoWithInvites,
                for: conversationId
            )
        } catch {
            Log.error("Error applying global include-info preference: \(error)")
        }
    }

    @MainActor
    private func handleJoinFailedState(_ error: InviteJoinError) {
        cleanUpUIForError()

        let inviteCode = extractInviteCode(from: conversationState)

        guard error.errorType == .genericFailure, let inviteCode else {
            let title: String
            switch error.errorType {
            case .conversationExpired, .conversationNotFound, .consentNotAllowed:
                title = "Convo no longer exists"
            case .genericFailure:
                title = "Couldn't join"
            }
            displayError = IdentifiableError(title: title, description: error.userFacingMessage, retryAction: nil)
            return
        }

        displayError = IdentifiableError(
            title: "Couldn't join",
            description: error.userFacingMessage,
            retryAction: .joinConversation(inviteCode: inviteCode)
        )
    }

    @MainActor
    private func handleErrorState(_ error: Error) {
        cleanUpUIForError()
        currentError = error

        Log.error("Conversation state error: \(error.localizedDescription)")

        guard let stateMachineError = error as? ConversationStateMachineError else {
            displayError = (error as? DisplayError).map { IdentifiableError(error: $0) }
                ?? IdentifiableError(title: "Failed creating", description: "Please try again.")

            if startedWithFullscreenScanner {
                showingFullScreenScanner = true
            }
            return
        }

        switch stateMachineError {
        case .timedOut, .stateMachineError:
            showRetryableError(for: stateMachineError)
        default:
            displayError = IdentifiableError(error: stateMachineError)
        }
    }

    @MainActor
    private func cleanUpUIForError() {
        qrScannerViewModel.resetScanning()
        conversationViewModel?.isWaitingForInviteAcceptance = false
        isCreatingConversation = false

        if startedWithFullscreenScanner {
            conversationViewModel?.showsInfoView = false
        }
    }

    @MainActor
    private func showRetryableError(for error: ConversationStateMachineError) {
        let inviteCode = cachedInviteCode ?? qrScannerViewModel.scannedCode

        let retryAction: RetryAction = if let inviteCode {
            .joinConversation(inviteCode: inviteCode)
        } else {
            .createConversation
        }

        displayError = IdentifiableError(
            title: error.title,
            description: error.description,
            retryAction: retryAction
        )

        if startedWithFullscreenScanner {
            showingFullScreenScanner = true
        }
    }

    private func extractInviteCode(from state: ConversationStateMachine.State) -> String? {
        switch state {
        case .validating(let inviteCode):
            return inviteCode
        case .validated(let invite, _, _, _), .joining(let invite, _):
            return try? invite.toURLSafeSlug()
        default:
            return nil
        }
    }
}

private extension NewConversationMode {
    var isNewConversation: Bool {
        switch self {
        case .newConversation, .newAgent, .newConversationWithMembers, .newConversationWithTemplate:
            return true
        case .existingConversation, .scanner, .joinInvite:
            return false
        }
    }
}
