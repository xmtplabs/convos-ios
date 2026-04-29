import Combine
import ConvosConnections
import ConvosCore
import SwiftUI

@MainActor @Observable
final class ConnectionsListViewModel {
    struct Row: Identifiable, Hashable {
        enum Source: Hashable {
            case cloud(CloudConnectionServiceInfo, CloudConnection?)
            case device(ConnectionKind, ConnectionAuthorizationStatus?)
        }

        let id: String
        let title: String
        let subtitle: String
        let source: Source
        let isOn: Bool
        let isToggleEnabled: Bool
    }

    private(set) var connections: [CloudConnection] = []
    private(set) var rows: [Row] = []
    private(set) var isConnecting: Bool = false
    private(set) var error: Error?

    private let cloudConnectionManager: any CloudConnectionManagerProtocol
    private let cloudConnectionRepository: any CloudConnectionRepositoryProtocol
    private let deviceConnectionAuthorizer: any DeviceConnectionAuthorizer
    private var cancellable: AnyCancellable?

    init(
        cloudConnectionManager: any CloudConnectionManagerProtocol,
        cloudConnectionRepository: any CloudConnectionRepositoryProtocol,
        deviceConnectionAuthorizer: any DeviceConnectionAuthorizer
    ) {
        self.cloudConnectionManager = cloudConnectionManager
        self.cloudConnectionRepository = cloudConnectionRepository
        self.deviceConnectionAuthorizer = deviceConnectionAuthorizer

        cancellable = cloudConnectionRepository.connectionsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                self?.connections = connections.filter { $0.provider == .composio }
                self?.rebuildRows()
            }

        rebuildRows()
    }

    func toggle(_ row: Row) {
        switch row.source {
        case .cloud(_, let connection):
            guard !isConnecting else { return }
            if let connection {
                disconnect(connection.id)
            } else if case .cloud(let service, _) = row.source {
                connect(serviceId: service.id)
            }
        case .device(let kind, let status):
            guard row.isToggleEnabled else { return }
            Task {
                do {
                    if status == nil || status == .notDetermined {
                        _ = try await self.deviceConnectionAuthorizer.requestAuthorization(for: kind)
                    }
                } catch {
                    await MainActor.run {
                        self.error = error
                    }
                }
                await MainActor.run {
                    rebuildRows()
                }
            }
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
                } else {
                    self.error = oauthError
                }
            } catch {
                self.error = error
            }
            isConnecting = false
            rebuildRows()
        }
    }

    func disconnect(_ connectionId: String) {
        Task {
            do {
                try await cloudConnectionManager.disconnect(connectionId: connectionId)
            } catch {
                self.error = error
            }
            rebuildRows()
        }
    }

    func refresh() {
        Task {
            _ = try? await cloudConnectionManager.refreshConnections()
            rebuildRows()
        }
    }

    private func rebuildRows() {
        Task { [connections, deviceConnectionAuthorizer] in
            var builtRows: [Row] = []

            for service in CloudConnectionServiceCatalog.all {
                let active = connections.first(where: { $0.serviceId == service.id })
                builtRows.append(
                    Row(
                        id: "cloud.\(service.id)",
                        title: service.displayName,
                        subtitle: service.subtitle,
                        source: .cloud(service, active),
                        isOn: active != nil,
                        isToggleEnabled: !isConnecting
                    )
                )
            }

            for kind in ConnectionKind.allCases {
                let status: ConnectionAuthorizationStatus?
                switch kind {
                case .homeKit:
                    status = nil
                default:
                    status = await deviceConnectionAuthorizer.currentAuthorization(for: kind)
                }
                builtRows.append(
                    Row(
                        id: "device.\(kind.rawValue)",
                        title: kind.displayName,
                        subtitle: deviceSubtitle(for: status),
                        source: .device(kind, status),
                        isOn: status?.canDeliverData ?? false,
                        isToggleEnabled: status != .unavailable && status != .denied
                    )
                )
            }

            builtRows.sort { lhs, rhs in lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
            await MainActor.run {
                self.rows = builtRows
            }
        }
    }

    private func deviceSubtitle(for status: ConnectionAuthorizationStatus?) -> String {
        switch status {
        case .authorized:
            return "Allowed on this device"
        case .partial:
            return "Partially allowed on this device"
        case .notDetermined:
            return "Not allowed yet"
        case .denied:
            return "Denied in Apple settings"
        case .unavailable:
            return "Unavailable on this device"
        case .none:
            return "Tap to check permission"
        }
    }
}
