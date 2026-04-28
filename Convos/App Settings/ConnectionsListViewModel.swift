import Combine
import ConvosCore
import SwiftUI

@MainActor @Observable
final class ConnectionsListViewModel {
    private(set) var connections: [CloudConnection] = []
    private(set) var isConnecting: Bool = false
    private(set) var error: Error?

    private let cloudConnectionManager: any CloudConnectionManagerProtocol
    private let cloudConnectionRepository: any CloudConnectionRepositoryProtocol
    private var cancellable: AnyCancellable?

    init(
        cloudConnectionManager: any CloudConnectionManagerProtocol,
        cloudConnectionRepository: any CloudConnectionRepositoryProtocol
    ) {
        self.cloudConnectionManager = cloudConnectionManager
        self.cloudConnectionRepository = cloudConnectionRepository

        cancellable = cloudConnectionRepository.connectionsPublisher()
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
                _ = try await cloudConnectionManager.connect(serviceId: serviceId)
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
                try await cloudConnectionManager.disconnect(connectionId: connectionId)
            } catch {
                self.error = error
            }
        }
    }

    func refresh() {
        Task {
            _ = try? await cloudConnectionManager.refreshConnections()
        }
    }
}
