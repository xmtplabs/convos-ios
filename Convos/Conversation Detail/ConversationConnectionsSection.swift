import Combine
import ConvosConnections
import ConvosCore
import SwiftUI

@MainActor @Observable
final class ConversationConnectionsViewModel {
    struct DeviceConnection: Identifiable, Hashable {
        let kind: ConnectionKind
        let isEnabled: Bool

        var id: String { kind.rawValue }
    }

    private(set) var connections: [CloudConnection] = []
    private(set) var grantedConnectionIds: Set<String> = []
    private(set) var deviceConnections: [DeviceConnection] = ConnectionKind.allCases
        .sorted { $0.displayName < $1.displayName }
        .map { DeviceConnection(kind: $0, isEnabled: false) }

    private let conversationId: String
    private let cloudConnectionRepository: any CloudConnectionRepositoryProtocol
    private let grantWriter: any CloudConnectionGrantWriterProtocol
    private let connectionEventWriter: any ConnectionEventWriterProtocol
    private let enablementStore: any EnablementStore
    private var connectionsCancellable: AnyCancellable?
    private var grantsCancellable: AnyCancellable?

    init(
        conversationId: String,
        cloudConnectionRepository: any CloudConnectionRepositoryProtocol,
        grantWriter: any CloudConnectionGrantWriterProtocol,
        connectionEventWriter: any ConnectionEventWriterProtocol,
        enablementStore: any EnablementStore
    ) {
        self.conversationId = conversationId
        self.cloudConnectionRepository = cloudConnectionRepository
        self.grantWriter = grantWriter
        self.connectionEventWriter = connectionEventWriter
        self.enablementStore = enablementStore

        connectionsCancellable = cloudConnectionRepository.connectionsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                self?.connections = connections.filter { $0.provider == .composio }
            }

        grantsCancellable = cloudConnectionRepository.grantsPublisher(for: conversationId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] grants in
                self?.grantedConnectionIds = Set(grants.map(\.connectionId))
            }

        refreshDeviceConnections()
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

    func toggleDeviceConnection(_ kind: ConnectionKind) {
        guard let index = deviceConnections.firstIndex(where: { $0.kind == kind }) else { return }
        let newValue = !deviceConnections[index].isEnabled
        deviceConnections[index] = DeviceConnection(kind: kind, isEnabled: newValue)

        Task {
            for capability in ConnectionCapability.allCases {
                await enablementStore.setEnabled(newValue, kind: kind, capability: capability, conversationId: conversationId)
            }
            if newValue {
                try? await connectionEventWriter.sendGranted(providerId: "device.\(kind.rawValue)", in: conversationId)
            } else {
                try? await connectionEventWriter.sendRevoked(providerId: "device.\(kind.rawValue)", in: conversationId)
            }
            await MainActor.run {
                refreshDeviceConnections()
            }
        }
    }

    var hasConnections: Bool {
        true
    }

    private func refreshDeviceConnections() {
        Task { [self] in
            var items: [DeviceConnection] = []
            for kind in ConnectionKind.allCases {
                let isReadEnabled = await self.enablementStore.isEnabled(kind: kind, capability: .read, conversationId: self.conversationId)
                var hasWrite = false
                for capability in ConnectionCapability.allCases where capability.isWrite {
                    if await self.enablementStore.isEnabled(kind: kind, capability: capability, conversationId: self.conversationId) {
                        hasWrite = true
                        break
                    }
                }
                items.append(DeviceConnection(kind: kind, isEnabled: isReadEnabled || hasWrite))
            }
            await MainActor.run {
                self.deviceConnections = items.sorted { $0.kind.displayName < $1.kind.displayName }
            }
        }
    }
}

struct ConversationConnectionsSection: View {
    @Bindable var viewModel: ConversationConnectionsViewModel

    var body: some View {
        Section {
            ForEach(viewModel.deviceConnections) { connection in
                FeatureRowItem(
                    imageName: nil,
                    symbolName: connection.kind.systemImageName,
                    title: connection.kind.displayName,
                    subtitle: "Shared from this device",
                    iconBackgroundColor: .colorFillMinimal,
                    iconForegroundColor: .colorTextPrimary
                ) {
                    Toggle("", isOn: Binding(
                        get: { connection.isEnabled },
                        set: { _ in viewModel.toggleDeviceConnection(connection.kind) }
                    ))
                    .labelsHidden()
                }
            }

            ForEach(viewModel.connections) { connection in
                let info = CloudConnectionServiceCatalog.info(for: connection.serviceId)
                FeatureRowItem(
                    imageName: nil,
                    symbolName: info?.iconSystemName ?? "link",
                    title: CloudConnectionServiceCatalog.displayName(for: connection.serviceId, fallback: connection.serviceName),
                    subtitle: "Share with this conversation",
                    iconBackgroundColor: .colorFillMinimal,
                    iconForegroundColor: .colorTextPrimary
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
