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
            // Handle the fetch per-element so a transient error yields a default
            // rather than failing the observation, which would complete the
            // stream (via replaceError) and freeze the My Profile screen until a
            // re-subscribe. The trailing replaceError remains only as the
            // Error -> Never conversion for an unrecoverable database error.
            .tracking { db -> Profile in
                do {
                    return try Self.observedProfile(db, inboxId: inboxId, conversationId: conversationId)
                } catch {
                    return .empty(inboxId: inboxId, conversationId: conversationId)
                }
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
            try Self.observedProfile(db, inboxId: inboxId, conversationId: conversationId)
        }
    }

    /// Reads the current user's identity from the canonical `DBMyProfile` - the
    /// single source of truth the "My Info" editor and every self-write path
    /// (`publishMyProfile`, the settings editor) write, keyed per inbox - plus
    /// the latest self avatar slot from `DBProfileAvatar`. The legacy
    /// per-conversation `member_profile` row is not consulted. Reading the avatar
    /// here (inside the tracked observation) means a self-avatar upload surfaces
    /// on `fetch()` / `myProfilePublisher` instead of being dropped.
    ///
    /// Internal (not private) so the avatar-surfacing behavior can be unit-tested
    /// against a seeded database.
    static func observedProfile(_ db: Database, inboxId: String, conversationId: String) throws -> Profile {
        guard let selfRow = try DBMyProfile.filter(DBMyProfile.Columns.inboxId == inboxId).fetchOne(db) else {
            return .empty(inboxId: inboxId, conversationId: conversationId)
        }
        // Newest slot for this inbox (matching the roster's newest-per-inbox
        // resolution). Read the base table directly so the observation tracks it.
        let avatar = try DBProfileAvatar
            .filter(DBProfileAvatar.Columns.inboxId == inboxId)
            .order(DBProfileAvatar.Columns.updatedAt.desc, DBProfileAvatar.Columns.conversationId.desc)
            .fetchOne(db)
        return Profile(
            inboxId: inboxId,
            conversationId: conversationId,
            name: (selfRow.name?.isEmpty ?? true) ? nil : selfRow.name,
            avatar: avatar?.url,
            avatarSalt: avatar?.salt,
            avatarNonce: avatar?.nonce,
            avatarKey: avatar?.encryptionKey,
            metadata: selfRow.metadata
        )
    }
}

enum MyProfileRepositoryError: Error {
    case inboxNotReady
}
