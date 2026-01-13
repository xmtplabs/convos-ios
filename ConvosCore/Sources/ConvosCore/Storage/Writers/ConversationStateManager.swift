import Combine
import Foundation
import GRDB
import Observation

// MARK: - Observer Protocol

public protocol ConversationStateObserver: AnyObject {
    func conversationStateDidChange(_ state: ConversationStateMachine.State)
}

// MARK: - StateManager Protocol

public protocol ConversationStateManagerProtocol: AnyObject, DraftConversationWriterProtocol {
    // State Management
    var currentState: ConversationStateMachine.State { get }

    // Observer Management
    @MainActor func removeObserver(_ observer: ConversationStateObserver)
    @MainActor func observeState(_ handler: @escaping (ConversationStateMachine.State) -> Void) -> ConversationStateObserverHandle

    // Error Recovery
    func resetFromError() async

    // Dependencies
    var myProfileWriter: any MyProfileWriterProtocol { get }
    var draftConversationRepository: any DraftConversationRepositoryProtocol { get }
    var conversationConsentWriter: any ConversationConsentWriterProtocol { get }
    var conversationLocalStateWriter: any ConversationLocalStateWriterProtocol { get }
    var conversationMetadataWriter: any ConversationMetadataWriterProtocol { get }
}

// MARK: - State Manager Implementation

@Observable
public final class ConversationStateManager: ConversationStateManagerProtocol {
    // MARK: - State Properties

    public private(set) var currentState: ConversationStateMachine.State = .uninitialized
    public private(set) var isReady: Bool = false
    public private(set) var hasError: Bool = false
    public private(set) var errorMessage: String?

    // MARK: - DraftConversationWriterProtocol Properties

    private let conversationIdSubject: CurrentValueSubject<String, Never>
    private let sentMessageSubject: PassthroughSubject<String, Never> = .init()

    public var conversationId: String {
        conversationIdSubject.value
    }

    public var conversationIdPublisher: AnyPublisher<String, Never> {
        conversationIdSubject.eraseToAnyPublisher()
    }

    public var sentMessage: AnyPublisher<String, Never> {
        sentMessageSubject.eraseToAnyPublisher()
    }

    // MARK: - Dependencies

    public let myProfileWriter: any MyProfileWriterProtocol
    public let conversationConsentWriter: any ConversationConsentWriterProtocol
    public let conversationLocalStateWriter: any ConversationLocalStateWriterProtocol
    public let conversationMetadataWriter: any ConversationMetadataWriterProtocol
    public let draftConversationRepository: any DraftConversationRepositoryProtocol

    // MARK: - Private Properties

    private let inboxStateManager: any InboxStateManagerProtocol
    private let identityStore: any KeychainIdentityStoreProtocol
    private let databaseReader: any DatabaseReader
    private let databaseWriter: any DatabaseWriter
    private let stateMachine: ConversationStateMachine

    private var stateObservationTask: Task<Void, Never>?
    private var initializationTask: Task<Void, Never>?
    private var observers: [WeakObserver] = []
    private var cancellables: Set<AnyCancellable> = .init()

    private struct WeakObserver {
        weak var observer: ConversationStateObserver?
    }

    // MARK: - Initialization

    public init(
        inboxStateManager: any InboxStateManagerProtocol,
        identityStore: any KeychainIdentityStoreProtocol,
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        environment: AppEnvironment,
        conversationId: String? = nil
    ) {
        self.inboxStateManager = inboxStateManager
        self.identityStore = identityStore
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter

        // Use provided conversationId or generate a new draft ID
        let initialConversationId = conversationId ?? DBConversation.generateDraftConversationId()
        self.conversationIdSubject = .init(initialConversationId)

        // Initialize writers
        let inviteWriter = InviteWriter(identityStore: identityStore, databaseWriter: databaseWriter)
        self.conversationMetadataWriter = ConversationMetadataWriter(
            inboxStateManager: inboxStateManager,
            inviteWriter: inviteWriter,
            databaseWriter: databaseWriter
        )

        self.myProfileWriter = MyProfileWriter(
            inboxStateManager: inboxStateManager,
            databaseWriter: databaseWriter
        )

        self.conversationConsentWriter = ConversationConsentWriter(
            inboxStateManager: inboxStateManager,
            databaseWriter: databaseWriter
        )

        self.conversationLocalStateWriter = ConversationLocalStateWriter(
            databaseWriter: databaseWriter
        )

        self.draftConversationRepository = DraftConversationRepository(
            dbReader: databaseReader,
            conversationId: conversationIdSubject.value,
            conversationIdPublisher: conversationIdSubject.eraseToAnyPublisher(),
            inboxStateManager: inboxStateManager
        )

        // Initialize state machine
        self.stateMachine = ConversationStateMachine(
            inboxStateManager: inboxStateManager,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment
        )

        setupStateObservation()

        // If using an existing conversation, transition state machine to ready
        if let conversationId {
            initializationTask = Task { [stateMachine] in
                await stateMachine.useExisting(conversationId: conversationId)
            }
        }
    }

    deinit {
        stateObservationTask?.cancel()
        initializationTask?.cancel()
        cancellables.removeAll()
        observers.removeAll()
    }

    // MARK: - State Observation Setup

    private func setupStateObservation() {
        stateObservationTask = Task { [weak self] in
            guard let stateSequence = await self?.stateMachine.stateSequence else { return }

            for await state in stateSequence {
                guard let self else { break }

                await self.handleStateChange(state)

                if Task.isCancelled {
                    break
                }
            }
        }
    }

    @MainActor
    private func handleStateChange(_ state: ConversationStateMachine.State) {
        currentState = state

        switch state {
        case .ready(let result),
                .joining(invite: _, placeholder: let result):
            conversationIdSubject.send(result.conversationId)
            isReady = true
            hasError = false
            errorMessage = nil

        case .joinFailed(_, let error):
            isReady = false
            hasError = true
            errorMessage = error.userFacingMessage

        case .error(let error):
            isReady = false
            hasError = true
            errorMessage = error.localizedDescription

        default:
            isReady = false
            hasError = false
            errorMessage = nil
        }

        notifyObservers(state)
    }

    // MARK: - Observer Management

    @MainActor
    private func addObserver(_ observer: ConversationStateObserver) {
        observers.removeAll { $0.observer == nil }
        observers.append(WeakObserver(observer: observer))
        observer.conversationStateDidChange(currentState)
    }

    @MainActor
    public func removeObserver(_ observer: ConversationStateObserver) {
        observers.removeAll { $0.observer === observer }
    }

    private func notifyObservers(_ state: ConversationStateMachine.State) {
        // Take a snapshot of observers to iterate, so modifications during
        // callbacks don't interfere with iteration or get overwritten
        let snapshot = observers

        // Notify each observer in the snapshot
        for weakObserver in snapshot {
            weakObserver.observer?.conversationStateDidChange(state)
        }

        // Clean up nil observers, preserving any removals made during callbacks
        observers.removeAll { $0.observer == nil }
    }

    public func observeState(_ handler: @escaping (ConversationStateMachine.State) -> Void) -> ConversationStateObserverHandle {
        let observer = ClosureConversationStateObserver(handler: handler)
        addObserver(observer)
        return ConversationStateObserverHandle(observer: observer, manager: self)
    }

    // MARK: - DraftConversationWriterProtocol Methods

    public func createConversation() async throws {
        await stateMachine.create()
    }

    public func joinConversation(inviteCode: String) async throws {
        await stateMachine.join(inviteCode: inviteCode)
        // @jarodl This should wait for validation, but not readiness
    }

    public func send(text: String) async throws {
        await stateMachine.sendMessage(text: text)
        sentMessageSubject.send(text)
    }

    public func delete() async throws {
        try await inboxStateManager.delete()
        await stateMachine.delete()
    }

    public func resetFromError() async {
        await stateMachine.reset()
    }
}

// MARK: - Observer Helpers

public final class ClosureConversationStateObserver: ConversationStateObserver {
    private let handler: (ConversationStateMachine.State) -> Void

    init(handler: @escaping (ConversationStateMachine.State) -> Void) {
        self.handler = handler
    }

    public func conversationStateDidChange(_ state: ConversationStateMachine.State) {
        handler(state)
    }
}

public final class ConversationStateObserverHandle {
    private var observer: ClosureConversationStateObserver?
    private weak var manager: (any ConversationStateManagerProtocol)?

    init(observer: ClosureConversationStateObserver, manager: any ConversationStateManagerProtocol) {
        self.observer = observer
        self.manager = manager
    }

    public func cancel() {
        if let observer = observer {
            DispatchQueue.main.async { [weak self] in
                self?.manager?.removeObserver(observer)
            }
        }
        observer = nil
        manager = nil
    }
}
