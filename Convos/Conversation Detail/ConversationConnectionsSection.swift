import Combine
import ConvosCore
import SwiftUI

@MainActor @Observable
final class ConversationConnectionsViewModel {
    private(set) var connections: [Connection] = []
    private(set) var grantedConnectionIds: Set<String> = []

    private let conversationId: String
    private let connectionRepository: any ConnectionRepositoryProtocol
    private let grantWriter: any ConnectionGrantWriterProtocol
    private var connectionsCancellable: AnyCancellable?
    private var grantsCancellable: AnyCancellable?

    init(
        conversationId: String,
        connectionRepository: any ConnectionRepositoryProtocol,
        grantWriter: any ConnectionGrantWriterProtocol
    ) {
        self.conversationId = conversationId
        self.connectionRepository = connectionRepository
        self.grantWriter = grantWriter

        connectionsCancellable = connectionRepository.connectionsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                self?.connections = connections
            }

        grantsCancellable = connectionRepository.grantsPublisher(for: conversationId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] grants in
                self?.grantedConnectionIds = Set(grants.map(\.connectionId))
            }
    }

    func toggleGrant(for connectionId: String) {
        let isGranted = grantedConnectionIds.contains(connectionId)
        Task {
            do {
                if isGranted {
                    try await grantWriter.revokeGrant(connectionId: connectionId, from: conversationId)
                } else {
                    try await grantWriter.grantConnection(connectionId, to: conversationId)
                }
            } catch {
                Log.error("Failed to toggle connection grant: \(error.localizedDescription)")
            }
        }
    }

    var hasConnections: Bool {
        !connections.isEmpty
    }
}

struct ConversationConnectionsSection: View {
    @Bindable var viewModel: ConversationConnectionsViewModel

    var body: some View {
        Section {
            ForEach(viewModel.connections) { connection in
                let info = ConnectionServiceCatalog.info(for: connection.serviceId)
                FeatureRowItem(
                    imageName: nil,
                    symbolName: info?.iconSystemName ?? "link",
                    title: ConnectionServiceCatalog.displayName(for: connection.serviceId, fallback: connection.serviceName),
                    subtitle: "Share with this conversation",
                    iconBackgroundColor: info?.iconBackgroundColor ?? .gray,
                    iconForegroundColor: .white
                ) {
                    Toggle("", isOn: Binding(
                        get: { viewModel.grantedConnectionIds.contains(connection.id) },
                        set: { _ in viewModel.toggleGrant(for: connection.id) }
                    ))
                    .labelsHidden()
                }
            }
        } header: {
            Text("Connections")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.colorTextSecondary)
        }
    }
}
