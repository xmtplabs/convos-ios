import Combine
import Foundation
import GRDB

/// Loading status of the local user's global profile. `pending` means the
/// active inbox has not delivered a definitive answer yet (cold launch,
/// pairing transition); `loaded` carries the row, or nil when the user
/// genuinely has no global profile. Consumers that act on the profile being
/// absent (e.g. onboarding prompts) must wait for `loaded` rather than
/// treating `pending` as "no profile".
public enum MyGlobalProfileLoadState: Equatable, Sendable {
    case pending
    case loaded(MyProfile?)
}

/// Read access to the local user's global profile (`DBMyProfile`).
public protocol MyGlobalProfileRepositoryProtocol {
    var myGlobalProfilePublisher: AnyPublisher<MyProfile?, Never> { get }
    var myGlobalProfileLoadStatePublisher: AnyPublisher<MyGlobalProfileLoadState, Never> { get }
    func fetch() throws -> MyProfile?
}

final class MyGlobalProfileRepository: MyGlobalProfileRepositoryProtocol {
    let myGlobalProfilePublisher: AnyPublisher<MyProfile?, Never>
    let myGlobalProfileLoadStatePublisher: AnyPublisher<MyGlobalProfileLoadState, Never>

    private let databaseReader: any DatabaseReader
    private let sessionStateManager: any SessionStateManagerProtocol
    private let stateSubject: CurrentValueSubject<MyGlobalProfileLoadState, Never> = .init(.pending)
    private var stateObserver: StateObserverHandle?
    private var observationCancellable: AnyCancellable?
    private var observingInboxId: String?

    init(
        sessionStateManager: any SessionStateManagerProtocol,
        databaseReader: any DatabaseReader
    ) {
        self.databaseReader = databaseReader
        self.sessionStateManager = sessionStateManager
        self.myGlobalProfileLoadStatePublisher = stateSubject.eraseToAnyPublisher()
        // The profile publisher stays quiet until the first definitive
        // answer, so subscribers no longer receive a synthetic nil replay
        // that is indistinguishable from "user has no profile".
        self.myGlobalProfilePublisher = stateSubject
            .compactMap { (state: MyGlobalProfileLoadState) -> MyProfile?? in
                guard case .loaded(let profile) = state else { return nil }
                return .some(profile)
            }
            .eraseToAnyPublisher()

        stateObserver = sessionStateManager.observeState { [weak self] state in
            self?.handleInboxStateChange(state)
        }
    }

    deinit {
        stateObserver?.cancel()
        observationCancellable?.cancel()
    }

    func fetch() throws -> MyProfile? {
        guard case .ready(let result) = sessionStateManager.currentState else {
            throw MyGlobalProfileRepositoryError.inboxNotReady
        }
        return try databaseReader.read { db in
            try DBMyProfile
                .filter(DBMyProfile.Columns.inboxId == result.client.inboxId)
                .fetchOne(db)?
                .hydrate()
        }
    }

    private func handleInboxStateChange(_ state: SessionStateMachine.State) {
        switch state {
        case .ready(let result):
            startObserving(inboxId: result.client.inboxId)
        case .idle:
            // No active inbox means the profile is unknown again, not
            // known-absent: teardown and pairing transitions pass through
            // here and must not read as "user has no profile".
            stateSubject.send(.pending)
            observationCancellable?.cancel()
            observingInboxId = nil
        default:
            break
        }
    }

    private func startObserving(inboxId: String) {
        guard observingInboxId != inboxId else { return }
        observingInboxId = inboxId
        observationCancellable?.cancel()
        observationCancellable = ValueObservation
            .tracking { db in
                try DBMyProfile
                    .filter(DBMyProfile.Columns.inboxId == inboxId)
                    .fetchOne(db)?
                    .hydrate()
            }
            .publisher(in: databaseReader)
            .replaceError(with: nil)
            .sink { [weak self] profile in
                self?.stateSubject.send(.loaded(profile))
            }
    }
}

enum MyGlobalProfileRepositoryError: Error {
    case inboxNotReady
}

extension DBMyProfile {
    func hydrate() -> MyProfile {
        MyProfile(
            inboxId: inboxId,
            name: name,
            imageData: imageData,
            imageAssetIdentifier: imageAssetIdentifier,
            imageContentDigest: imageContentDigest,
            metadata: metadata,
            updatedAt: updatedAt
        )
    }
}
