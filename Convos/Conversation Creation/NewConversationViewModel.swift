import Combine
import ConvosCore
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
    case scanner
    case joinInvite(code: String)
}

@MainActor
@Observable
class NewConversationViewModel: Identifiable {
    // MARK: - Public

    let session: any SessionManagerProtocol
    private(set) var conversationViewModel: ConversationViewModel?
    let qrScannerViewModel: QRScannerViewModel
    private(set) var messagesTopBarTrailingItem: MessagesViewTopBarTrailingItem = .share
    private(set) var messagesTopBarTrailingItemEnabled: Bool = false
    private(set) var messagesTextFieldEnabled: Bool = false
    private let startedWithFullscreenScanner: Bool
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

    private(set) var isCreatingConversation: Bool = false
    private(set) var currentError: Error?
    private(set) var conversationState: ConversationStateMachine.State = .uninitialized
    private var cachedInviteCode: String?

    // MARK: - Private

    private var conversationStateManager: (any ConversationStateManagerProtocol)?
    private var acquiredMessagingService: AnyMessagingService?
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
    private var stateObserverHandle: ConversationStateObserverHandle?
    @ObservationIgnored
    private var dismissAction: DismissAction?
    private var pendingInviteCode: String?

    // MARK: - Init

    init(
        session: any SessionManagerProtocol,
        mode: NewConversationMode
    ) {
        self.session = session
        self.qrScannerViewModel = QRScannerViewModel()

        switch mode {
        case .newConversation:
            self.autoCreateConversation = true
            self.startedWithFullscreenScanner = false
            self.showingFullScreenScanner = false
            self.allowsDismissingScanner = true

        case .scanner:
            self.autoCreateConversation = false
            self.startedWithFullscreenScanner = true
            self.showingFullScreenScanner = true
            self.allowsDismissingScanner = true

        case .joinInvite:
            self.autoCreateConversation = false
            self.startedWithFullscreenScanner = false
            self.showingFullScreenScanner = false
            self.allowsDismissingScanner = true
        }

        self.isCreatingConversation = mode.isNewConversation
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
        stateObserverHandle?.cancel()
    }

    // MARK: - Inbox Acquisition

    private func acquireInbox(mode: NewConversationMode) {
        inboxAcquisitionTask?.cancel()
        inboxAcquisitionTask = Task { [weak self] in
            guard let self else { return }

            switch mode {
            case .newConversation:
                let (messagingService, existingConversationId) = await session.addInbox()
                guard !Task.isCancelled else { return }
                configureWithMessagingService(
                    messagingService,
                    existingConversationId: existingConversationId
                )

            case .scanner, .joinInvite:
                let messagingService = await session.addInboxOnly()
                guard !Task.isCancelled else { return }
                configureWithMessagingService(messagingService, existingConversationId: nil)
            }

            if case .joinInvite(let code) = mode {
                joinConversation(inviteCode: code)
            }
        }
    }

    private func configureWithMessagingService(
        _ messagingService: AnyMessagingService,
        existingConversationId: String?
    ) {
        let stateManager: any ConversationStateManagerProtocol
        if let existingConversationId {
            stateManager = messagingService.conversationStateManager(for: existingConversationId)
        } else {
            stateManager = messagingService.conversationStateManager()
        }
        self.conversationStateManager = stateManager
        self.acquiredMessagingService = messagingService
        let draftConversation: Conversation = .empty(
            id: stateManager.draftConversationRepository.conversationId,
            clientId: messagingService.clientId
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
        self.conversationViewModel = convoVM
        setupObservations()
        setupStateObservation()

        if let pendingCode = pendingInviteCode {
            pendingInviteCode = nil
            joinConversation(inviteCode: pendingCode)
        }

        if autoCreateConversation && existingConversationId == nil {
            newConversationTask = Task { [weak self, stateManager] in
                guard self != nil else { return }
                guard !Task.isCancelled else { return }
                do {
                    try await stateManager.createConversation()
                } catch {
                    Log.error("Error auto-creating conversation: \(error.localizedDescription)")
                    guard !Task.isCancelled else { return }
                    await MainActor.run { [weak self] in
                        self?.handleCreationError(error)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    func onScanInviteCode() {
        presentingJoinConversationSheet = true
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

    func deleteConversation() {
        Log.info("Deleting conversation")
        newConversationTask?.cancel()
        joinConversationTask?.cancel()
        let clientId = conversationViewModel?.conversation.clientId ?? acquiredMessagingService?.clientId
        let inboxId = conversationViewModel?.conversation.inboxId
        guard let clientId else { return }
        Task { [session] in
            do {
                try await session.deleteInbox(clientId: clientId, inboxId: inboxId ?? "")
            } catch {
                Log.error("Failed deleting conversation: \(error.localizedDescription)")
            }
        }
    }

    func setDismissAction(_ action: DismissAction) {
        dismissAction = action
    }

    func dismissWithDeletion() {
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
        switch action {
        case .createConversation:
            guard let conversationStateManager else { return }
            newConversationTask?.cancel()
            newConversationTask = Task { [weak self, conversationStateManager] in
                guard self != nil else { return }
                guard !Task.isCancelled else { return }
                do {
                    try await conversationStateManager.createConversation()
                } catch {
                    Log.error("Error retrying conversation creation: \(error.localizedDescription)")
                    guard !Task.isCancelled else { return }
                    await MainActor.run { [weak self] in
                        self?.handleCreationError(error)
                    }
                }
            }
        case .joinConversation(let inviteCode):
            joinConversation(inviteCode: inviteCode)
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

    @MainActor
    private func setupStateObservation() {
        guard let conversationStateManager else { return }
        stateObserverHandle?.cancel()
        stateObserverHandle = conversationStateManager.observeState { [weak self] state in
            self?.handleStateChange(state)
        }
    }

    @MainActor
    private func handleStateChange(_ state: ConversationStateMachine.State) {
        conversationState = state

        switch state {
        case .uninitialized:
            resetUIState()

        case .creating:
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
            if result.origin != .existing || !startedWithFullscreenScanner {
                showingFullScreenScanner = false
            }
            currentError = nil

            Log.info("Conversation ready!")

        case .deleting:
            conversationViewModel?.isWaitingForInviteAcceptance = false
            isCreatingConversation = false
            currentError = nil

        case .joinFailed(_, let error):
            handleJoinFailedState(error)

        case .error(let error):
            handleErrorState(error)
        }
    }

    @MainActor
    private func handleJoinFailedState(_ error: InviteJoinError) {
        cleanUpUIForError()

        let inviteCode = extractInviteCode(from: conversationState)

        guard error.errorType == .genericFailure, let inviteCode else {
            let title = error.errorType == .conversationExpired ? "Convo no longer exists" : "Couldn't join"
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
            displayError = (error as? DisplayError).map { IdentifiableError(error: $0) }
                ?? IdentifiableError(title: "Failed creating", description: "Please try again.")
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

        guard let inviteCode else {
            displayError = IdentifiableError(
                title: "Couldn't create",
                description: "Failed to create conversation. Please try again.",
                retryAction: .createConversation
            )
            return
        }

        let description = switch error {
        case .timedOut:
            "Connection timed out. Please check your network and try again."
        case .stateMachineError:
            "Something went wrong. Please try again."
        default:
            "Please try again."
        }

        displayError = IdentifiableError(
            title: "Couldn't join",
            description: description,
            retryAction: .joinConversation(inviteCode: inviteCode)
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
                .filter { $0.contains { $0.base.content.showsInMessagesList } }
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
}

private extension NewConversationMode {
    var isNewConversation: Bool {
        if case .newConversation = self { return true }
        return false
    }
}
