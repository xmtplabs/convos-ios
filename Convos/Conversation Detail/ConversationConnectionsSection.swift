import Combine
import ConvosCore
import SwiftUI

@MainActor @Observable
final class ConversationConnectionsViewModel {
    private(set) var connections: [CloudConnection] = []
    private(set) var grantedConnectionIds: Set<String> = []

    private let conversationId: String
    private let cloudConnectionRepository: any CloudConnectionRepositoryProtocol
    private let grantWriter: any CloudConnectionGrantWriterProtocol
    private var connectionsCancellable: AnyCancellable?
    private var grantsCancellable: AnyCancellable?

    init(
        conversationId: String,
        cloudConnectionRepository: any CloudConnectionRepositoryProtocol,
        grantWriter: any CloudConnectionGrantWriterProtocol
    ) {
        self.conversationId = conversationId
        self.cloudConnectionRepository = cloudConnectionRepository
        self.grantWriter = grantWriter

        connectionsCancellable = cloudConnectionRepository.connectionsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                self?.connections = connections
            }

        grantsCancellable = cloudConnectionRepository.grantsPublisher(for: conversationId)
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
                let info = CloudConnectionServiceCatalog.info(for: connection.serviceId)
                FeatureRowItem(
                    imageName: nil,
                    symbolName: info?.iconSystemName ?? "link",
                    title: CloudConnectionServiceCatalog.displayName(for: connection.serviceId, fallback: connection.serviceName),
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
