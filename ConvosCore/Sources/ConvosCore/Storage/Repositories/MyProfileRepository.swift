import Combine
import Foundation
import GRDB

public protocol MyProfileRepositoryProtocol {
    var myProfilePublisher: AnyPublisher<Profile, Never> { get }
    func fetch() throws -> Profile
    func suspendObservation()
    func resumeObservation()
}

class MyProfileRepository: MyProfileRepositoryProtocol {
    let myProfilePublisher: AnyPublisher<Profile, Never>

    private let databaseReader: any DatabaseReader
    private let sessionStateManager: any SessionStateManagerProtocol
    private var conversationId: String {
        conversationIdSubject.value
    }
    private let conversationIdSubject: CurrentValueSubject<String, Never>
    private var stateObserver: StateObserverHandle?
    private let profileSubject: CurrentValueSubject<Profile?, Never> = .init(nil)
    private var conversationIdCancellable: AnyCancellable?
    private var cancellables: Set<AnyCancellable> = .init()

    /// When true, observation values are buffered instead of emitted
    private var isSuspended: Bool = false
    /// Stores the latest profile received while suspended
    private var pendingProfile: Profile?

    init(
        sessionStateManager: any SessionStateManagerProtocol,
        databaseReader: any DatabaseReader,
        conversationId: String
    ) {
        self.databaseReader = databaseReader
        self.sessionStateManager = sessionStateManager
        self.conversationIdSubject = .init(conversationId)

        // Set up publisher that emits profiles when inbox state or conversation changes
        self.myProfilePublisher = profileSubject
            .compactMap { $0 }
            .eraseToAnyPublisher()

        stateObserver = sessionStateManager.observeState { [weak self] state in
            self?.handleInboxStateChange(state)
        }
    }

    init(
        sessionStateManager: any SessionStateManagerProtocol,
        databaseReader: any DatabaseReader,
        conversationId: String,
        conversationIdPublisher: AnyPublisher<String, Never>
    ) {
        self.databaseReader = databaseReader
        self.sessionStateManager = sessionStateManager
        self.conversationIdSubject = .init(conversationId)

        // Set up publisher that emits profiles when inbox state or conversation changes
        self.myProfilePublisher = profileSubject
            .compactMap { $0 }
            .eraseToAnyPublisher()

        stateObserver = sessionStateManager.observeState { [weak self] state in
            self?.handleInboxStateChange(state)
        }

        conversationIdCancellable = conversationIdPublisher.sink { [weak self] conversationId in
            guard let self else { return }
            Log.info("Updating conversation id to \(conversationId)")
            self.conversationIdSubject.send(conversationId)
            // Re-observe profile for the new conversation
            if case .ready(let result) = self.sessionStateManager.currentState {
                self.startObservingProfile(for: result.client.inboxId, conversationId: conversationId)
            }
        }
    }

    deinit {
        stateObserver?.cancel()
        conversationIdCancellable?.cancel()
    }

    private func handleInboxStateChange(_ state: SessionStateMachine.State) {
        switch state {
        case .ready(let result):
            let inboxId = result.client.inboxId
            startObservingProfile(for: inboxId, conversationId: conversationId)
        case .idle:
            profileSubject.send(nil)
        default:
            break
        }
    }

    private func startObservingProfile(for inboxId: String, conversationId: String) {
        // Cancel previous observations
        cancellables.removeAll()

        let observation = ValueObservation
            .tracking { db in
                try DBMemberProfile
                    .fetchOne(db, conversationId: conversationId, inboxId: inboxId)?
                    .hydrateProfile() ?? .empty(inboxId: inboxId, conversationId: conversationId)
            }
            .publisher(in: databaseReader)
            .replaceError(with: .empty(inboxId: inboxId, conversationId: conversationId))

        observation
            .sink { [weak self] profile in
                guard let self else { return }
                if self.isSuspended {
                    // Buffer the latest value while suspended
                    self.pendingProfile = profile
                } else {
                    self.profileSubject.send(profile)
                }
            }
            .store(in: &cancellables)
    }

    func suspendObservation() {
        isSuspended = true
        pendingProfile = nil
    }

    func resumeObservation() {
        isSuspended = false
        // Emit the latest buffered value if any
        if let pending = pendingProfile {
            profileSubject.send(pending)
            pendingProfile = nil
        }
    }

    func fetch() throws -> Profile {
        guard case .ready(let result) = sessionStateManager.currentState else {
            throw MyProfileRepositoryError.inboxNotReady
        }
        let inboxId = result.client.inboxId

        let conversationId = self.conversationId
        return try databaseReader.read { db in
            try DBMemberProfile
                .fetchOne(db, conversationId: conversationId, inboxId: inboxId)?
                .hydrateProfile() ?? .empty(inboxId: inboxId, conversationId: conversationId)
        }
    }
}

enum MyProfileRepositoryError: Error {
    case inboxNotReady
}
