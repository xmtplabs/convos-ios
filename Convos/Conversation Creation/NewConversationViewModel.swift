import Combine
import ConvosCore
import SwiftUI

// MARK: - Error Types

struct IdentifiableError: Identifiable {
    let id: UUID = UUID()
    let error: DisplayError

    var title: String { error.title }
    var description: String { error.description }
}

struct GenericDisplayError: DisplayError {
    let title: String
    let description: String
}

@MainActor
@Observable
class NewConversationViewModel: Identifiable {
    // MARK: - Public

    let session: any SessionManagerProtocol
    let conversationViewModel: ConversationViewModel
    let qrScannerViewModel: QRScannerViewModel
    private(set) var messagesTopBarTrailingItem: MessagesViewTopBarTrailingItem = .scan
    private(set) var messagesTopBarTrailingItemEnabled: Bool = false
    private(set) var messagesTextFieldEnabled: Bool = false
    private(set) var shouldConfirmDeletingConversation: Bool = true
    private let startedWithFullscreenScanner: Bool
    let allowsDismissingScanner: Bool
    private let autoCreateConversation: Bool
    private(set) var showingFullScreenScanner: Bool
    var presentingJoinConversationSheet: Bool = false
    var displayError: IdentifiableError? {
        didSet {
            qrScannerViewModel.presentingInvalidInviteSheet = displayError != nil
            // Reset scanner when dismissing the error sheet to allow immediate re-scanning
            if oldValue != nil && displayError == nil {
                qrScannerViewModel.resetScanTimer()
                qrScannerViewModel.resetScanning()
            }
        }
    }

    // State tracking
    private(set) var isCreatingConversation: Bool = false
    private(set) var currentError: Error?
    private(set) var conversationState: ConversationStateMachine.State = .uninitialized

    // MARK: - Private

    private let conversationStateManager: any ConversationStateManagerProtocol
    @ObservationIgnored
    private var newConversationTask: Task<Void, Error>?
    @ObservationIgnored
    private var joinConversationTask: Task<Void, Error>?
    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored
    private var stateObserverHandle: ConversationStateObserverHandle?

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
            conversationStateManager: conversationStateManager
        )
        setupObservations()
        setupStateObservation()
        self.conversationViewModel.untitledConversationPlaceholder = "New convo"
        if showingFullScreenScanner {
            self.conversationViewModel.showsInfoView = false
        }
        if autoCreateConversation {
            newConversationTask = Task { [weak self] in
                guard let self else { return }
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
        cancellables.removeAll()
        newConversationTask?.cancel()
        joinConversationTask?.cancel()
        stateObserverHandle?.cancel()
    }

    // MARK: - Actions

    func onScanInviteCode() {
        presentingJoinConversationSheet = true
    }

    func joinConversation(inviteCode: String) {
        joinConversationTask?.cancel()
        joinConversationTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            do {
                // Request to join - this will trigger state changes through the observer
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
        Task { [weak self] in
            guard let self else { return }
            do {
                try await conversationStateManager.delete()
            } catch {
                Log.error("Failed deleting conversation: \(error.localizedDescription)")
            }
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

            // Set the display error
            if let displayError = error as? DisplayError {
                self.displayError = IdentifiableError(error: displayError)
            } else {
                // Fallback for non-DisplayError errors
                self.displayError = IdentifiableError(error: GenericDisplayError(
                    title: "Failed joining",
                    description: "Please try again."
                ))
            }
        }
    }

    @MainActor
    private func handleCreationError(_ error: Error) {
        currentError = error
        isCreatingConversation = false
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
            conversationViewModel.isWaitingForInviteAcceptance = false
            isCreatingConversation = false
            messagesTopBarTrailingItemEnabled = false
            messagesTextFieldEnabled = false
            if startedWithFullscreenScanner {
                conversationViewModel.showsInfoView = false
            } else {
                conversationViewModel.showsInfoView = true
            }
            currentError = nil
            qrScannerViewModel.resetScanning()

        case .creating:
            isCreatingConversation = true
            conversationViewModel.isWaitingForInviteAcceptance = false
            currentError = nil

        case .validating:
            conversationViewModel.isWaitingForInviteAcceptance = false
            isCreatingConversation = false
            currentError = nil

        case .validated:
            conversationViewModel.isWaitingForInviteAcceptance = false
            isCreatingConversation = false
            currentError = nil
            showingFullScreenScanner = false

        case .joining:
            // This is the waiting state - user is waiting for inviter to accept
            conversationViewModel.isWaitingForInviteAcceptance = true
            conversationViewModel.showsInfoView = true
            messagesTopBarTrailingItemEnabled = false
            messagesTopBarTrailingItem = .share
            messagesTextFieldEnabled = false
            shouldConfirmDeletingConversation = false
            conversationViewModel.untitledConversationPlaceholder = "Untitled"
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

        case .error(let error):
            qrScannerViewModel.resetScanning()
            conversationViewModel.isWaitingForInviteAcceptance = false
            isCreatingConversation = false
            currentError = error
            if startedWithFullscreenScanner {
                conversationViewModel.showsInfoView = false
            }
            Log.error("Conversation state error: \(error.localizedDescription)")
            // Handle specific error types
            handleError(error)
        }
    }

    @MainActor
    private func handleError(_ error: Error) {
        // Set the display error
        if let displayError = error as? DisplayError {
            self.displayError = IdentifiableError(error: displayError)
        } else {
            // Fallback for non-DisplayError errors
            self.displayError = IdentifiableError(error: GenericDisplayError(
                title: "Failed creating",
                description: "Please try again."
            ))
        }

        if startedWithFullscreenScanner {
            showingFullScreenScanner = true
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
        .first()
        .sink { [weak self] in
            guard let self else { return }
            messagesTopBarTrailingItem = .share
            shouldConfirmDeletingConversation = false
            conversationViewModel.untitledConversationPlaceholder = "Untitled"
        }
        .store(in: &cancellables)
    }
}
