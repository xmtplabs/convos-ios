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

@MainActor
@Observable
class NewConversationViewModel: Identifiable {
    // MARK: - Public

    let session: any SessionManagerProtocol
    let conversationViewModel: ConversationViewModel
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

    private let conversationStateManager: any ConversationStateManagerProtocol
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

    // MARK: - Init

    static func create(
        session: any SessionManagerProtocol,
        autoCreateConversation: Bool = false,
        showingFullScreenScanner: Bool = false,
        allowsDismissingScanner: Bool = true,
    ) async -> NewConversationViewModel {
        let messagingService = await session.addInbox()
        return NewConversationViewModel(
            session: session,
            messagingService: messagingService,
            autoCreateConversation: autoCreateConversation,
            showingFullScreenScanner: showingFullScreenScanner,
            allowsDismissingScanner: allowsDismissingScanner,
        )
    }

    /// Internal initializer for previews and tests
    internal init(
        session: any SessionManagerProtocol,
        messagingService: AnyMessagingService,
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

        let conversationStateManager = messagingService.conversationStateManager()
        self.conversationStateManager = conversationStateManager
        let draftConversation: Conversation = .empty(
            id: conversationStateManager.draftConversationRepository.conversationId,
            clientId: messagingService.clientId
        )
        self.conversationViewModel = .init(
            conversation: draftConversation,
            session: session,
            messagingService: messagingService,
            conversationStateManager: conversationStateManager
        )
        setupObservations()
        setupStateObservation()
        if showingFullScreenScanner {
            self.conversationViewModel.showsInfoView = false
        }
        if autoCreateConversation {
            newConversationTask = Task { [weak self, conversationStateManager] in
                guard self != nil else { return }
                guard !Task.isCancelled else { return }
                do {
                    try await conversationStateManager.createConversation()
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

    deinit {
        Log.info("deinit")
        // Note: AnyCancellable auto-cancels on dealloc, no need to clear manually
        newConversationTask?.cancel()
        joinConversationTask?.cancel()
        resetTask?.cancel()
        stateObserverHandle?.cancel()
    }

    // MARK: - Actions

    func onScanInviteCode() {
        presentingJoinConversationSheet = true
    }

    func joinConversation(inviteCode: String) {
        cachedInviteCode = inviteCode
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
        let clientId = conversationViewModel.conversation.clientId
        let inboxId = conversationViewModel.conversation.inboxId
        Task { [session] in
            do {
                try await session.deleteInbox(clientId: clientId, inboxId: inboxId)
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
        conversationViewModel.isWaitingForInviteAcceptance = false
        deleteConversation()
        dismissAction?()
    }

    func retryAction(_ action: RetryAction) {
        displayError = nil
        switch action {
        case .createConversation:
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
        conversationViewModel.isWaitingForInviteAcceptance = false
        isCreatingConversation = false
        currentError = nil
        qrScannerViewModel.resetScanning()

        if startedWithFullscreenScanner {
            conversationViewModel.showsInfoView = false
        } else {
            conversationViewModel.showsInfoView = true
        }
    }

    @MainActor
    private func setupStateObservation() {
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
            conversationViewModel.isWaitingForInviteAcceptance = false
            currentError = nil

        case .validating(let inviteCode):
            cachedInviteCode = inviteCode
            conversationViewModel.isWaitingForInviteAcceptance = false
            isCreatingConversation = false
            currentError = nil

        case .validated(let invite, _, _, _):
            cachedInviteCode = try? invite.toURLSafeSlug()
            conversationViewModel.isWaitingForInviteAcceptance = false
            isCreatingConversation = false
            currentError = nil
            showingFullScreenScanner = false

        case .joining(let invite, _):
            cachedInviteCode = try? invite.toURLSafeSlug()
            // This is the waiting state - user is waiting for inviter to accept
            conversationViewModel.isWaitingForInviteAcceptance = true
            conversationViewModel.showsInfoView = true
            messagesTopBarTrailingItemEnabled = false
            messagesTopBarTrailingItem = .share
            messagesTextFieldEnabled = false
            isCreatingConversation = false
            currentError = nil

            conversationViewModel.startOnboarding()
            Log.info("Waiting for invite acceptance...")

        case .ready(let result):
            if result.origin != .existing {
                conversationViewModel.startOnboarding()
            }

            if result.origin == .joined {
                conversationViewModel.inviteWasAccepted()
            } else {
                conversationViewModel.isWaitingForInviteAcceptance = false
            }

            conversationViewModel.showsInfoView = true
            messagesTopBarTrailingItemEnabled = true
            messagesTextFieldEnabled = true
            isCreatingConversation = false
            showingFullScreenScanner = false
            currentError = nil

            Log.info("Conversation ready!")

        case .deleting:
            conversationViewModel.isWaitingForInviteAcceptance = false
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
        conversationViewModel.isWaitingForInviteAcceptance = false
        isCreatingConversation = false

        if startedWithFullscreenScanner {
            conversationViewModel.showsInfoView = false
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
