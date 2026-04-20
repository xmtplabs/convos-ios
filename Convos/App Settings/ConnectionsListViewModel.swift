import Combine
import ConvosCore
import SwiftUI

@MainActor @Observable
final class ConnectionsListViewModel {
    private(set) var connections: [Connection] = []
    private(set) var isConnecting: Bool = false
    private(set) var error: Error?

    private let connectionManager: any ConnectionManagerProtocol
    private let connectionRepository: any ConnectionRepositoryProtocol
    private var cancellable: AnyCancellable?

    init(
        connectionManager: any ConnectionManagerProtocol,
        connectionRepository: any ConnectionRepositoryProtocol
    ) {
        self.connectionManager = connectionManager
        self.connectionRepository = connectionRepository

        cancellable = connectionRepository.connectionsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                self?.connections = connections
            }
    }

    func connect(serviceId: String) {
        guard !isConnecting else { return }
        isConnecting = true
        error = nil

        Task {
            do {
                _ = try await connectionManager.connect(serviceId: serviceId)
            } catch let oauthError as OAuthError {
                if case .cancelled = oauthError {
                    // user cancelled, no error to show
                } else {
                    self.error = oauthError
                }
            } catch {
                self.error = error
            }
            isConnecting = false
        }
    }

    func disconnect(_ connectionId: String) {
        Task {
            do {
                try await connectionManager.disconnect(connectionId: connectionId)
            } catch {
                self.error = error
            }
        }
    }

    func refresh() {
        Task {
            _ = try? await connectionManager.refreshConnections()
        }
    }
}
