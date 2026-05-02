import Combine
import Foundation
import GRDB

/// Read access to the local user's global profile (`DBMyProfile`).
public protocol MyGlobalProfileRepositoryProtocol {
    var myGlobalProfilePublisher: AnyPublisher<MyProfile?, Never> { get }
    func fetch() throws -> MyProfile?
}

final class MyGlobalProfileRepository: MyGlobalProfileRepositoryProtocol {
    let myGlobalProfilePublisher: AnyPublisher<MyProfile?, Never>

    private let databaseReader: any DatabaseReader
    private let sessionStateManager: any SessionStateManagerProtocol
    private let profileSubject: CurrentValueSubject<MyProfile?, Never> = .init(nil)
    private var stateObserver: StateObserverHandle?
    private var observationCancellable: AnyCancellable?

    init(
        sessionStateManager: any SessionStateManagerProtocol,
        databaseReader: any DatabaseReader
    ) {
        self.databaseReader = databaseReader
        self.sessionStateManager = sessionStateManager
        self.myGlobalProfilePublisher = profileSubject.eraseToAnyPublisher()

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
            profileSubject.send(nil)
            observationCancellable?.cancel()
        default:
            break
        }
    }

    private func startObserving(inboxId: String) {
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
                self?.profileSubject.send(profile)
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
            metadata: metadata,
            updatedAt: updatedAt
        )
    }
}
