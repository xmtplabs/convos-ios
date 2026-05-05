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

    struct CloudRow: Identifiable, Hashable {
        let serviceId: String
        let info: CloudConnectionServiceInfo
        /// `nil` when the user has no global `CloudConnection` for this service —
        /// toggling on must run OAuth before it can grant anything.
        let active: CloudConnection?
        let isGrantedForConversation: Bool

        var id: String { serviceId }
        var isOn: Bool { active != nil && isGrantedForConversation }
    }

    private(set) var cloudRows: [CloudRow] = []
    private(set) var deviceConnections: [DeviceConnection] = ConnectionKind.allCases
        .filter(SupportedConnections.isSupported)
        .sorted { $0.displayName < $1.displayName }
        .map { DeviceConnection(kind: $0, isEnabled: false) }
    private(set) var isConnecting: Bool = false
    private(set) var error: Error?

    private var connections: [CloudConnection] = []
    private var grantedConnectionIds: Set<String> = []

    private let conversationId: String
    private let cloudConnectionManager: any CloudConnectionManagerProtocol
    private let cloudConnectionRepository: any CloudConnectionRepositoryProtocol
    private let grantWriter: any CloudConnectionGrantWriterProtocol
    private let connectionEventWriter: any ConnectionEventWriterProtocol
    private let enablementStore: any EnablementStore
    private let capabilityResolver: any CapabilityResolver
    private var connectionsCancellable: AnyCancellable?
    private var grantsCancellable: AnyCancellable?

    init(
        conversationId: String,
        cloudConnectionManager: any CloudConnectionManagerProtocol,
        cloudConnectionRepository: any CloudConnectionRepositoryProtocol,
        grantWriter: any CloudConnectionGrantWriterProtocol,
        connectionEventWriter: any ConnectionEventWriterProtocol,
        enablementStore: any EnablementStore,
        capabilityResolver: any CapabilityResolver
    ) {
        self.conversationId = conversationId
        self.cloudConnectionManager = cloudConnectionManager
        self.cloudConnectionRepository = cloudConnectionRepository
        self.grantWriter = grantWriter
        self.connectionEventWriter = connectionEventWriter
        self.enablementStore = enablementStore
        self.capabilityResolver = capabilityResolver

        connectionsCancellable = cloudConnectionRepository.connectionsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                self?.connections = connections.filter { $0.provider == .composio }
                self?.rebuildCloudRows()
            }

        grantsCancellable = cloudConnectionRepository.grantsPublisher(for: conversationId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] grants in
                self?.grantedConnectionIds = Set(grants.map(\.connectionId))
                self?.rebuildCloudRows()
            }

        rebuildCloudRows()
        refreshDeviceConnections()
    }

    func toggleCloud(_ row: CloudRow) {
        guard !isConnecting else { return }
        let providerId = ProviderID(rawValue: "composio.\(row.serviceId)")
        if let active = row.active {
            if row.isGrantedForConversation {
                revokeGrant(connectionId: active.id, providerId: providerId)
            } else {
                grant(connectionId: active.id, providerId: providerId)
            }
        } else {
            connectAndGrant(serviceId: row.serviceId, providerId: providerId)
        }
    }

    func toggleDeviceConnection(_ kind: ConnectionKind) {
        guard let index = deviceConnections.firstIndex(where: { $0.kind == kind }) else { return }
        let newValue = !deviceConnections[index].isEnabled
        deviceConnections[index] = DeviceConnection(kind: kind, isEnabled: newValue)

        Task {
            // Read the store-side state once at the top so we can decide whether to emit
            // a grant/revoke event only when the persisted state actually changes. Without
            // this, rapid toggling fires redundant connection_event messages even when
            // every store write is a no-op (e.g. tap-on then tap-off before either Task
            // runs).
            let wasEnabled = await enablementStore.isEnabled(kind: kind, capability: .read, conversationId: conversationId)
            for capability in ConnectionCapability.allCases {
                await enablementStore.setEnabled(newValue, kind: kind, capability: capability, conversationId: conversationId)
            }
            if newValue != wasEnabled {
                if newValue {
                    try? await connectionEventWriter.sendGranted(providerId: "device.\(kind.rawValue)", in: conversationId)
                } else {
                    try? await connectionEventWriter.sendRevoked(providerId: "device.\(kind.rawValue)", in: conversationId)
                }
            }
            await MainActor.run {
                refreshDeviceConnections()
            }
        }
    }

    var hasConnections: Bool {
        true
    }

    private func grant(connectionId: String, providerId: ProviderID) {
        Task {
            do {
                try await grantWriter.grantConnection(connectionId, to: conversationId)
                try? await connectionEventWriter.sendGranted(providerId: providerId.rawValue, in: conversationId)
            } catch {
                Log.error("Failed to grant connection: \(error.localizedDescription)")
                self.error = error
            }
        }
    }

    private func revokeGrant(connectionId: String, providerId: ProviderID) {
        Task {
            do {
                try await grantWriter.revokeGrant(connectionId: connectionId, from: conversationId)
                // Drop this provider from every (subject, verb) row of the
                // resolver scoped to this conversation. Without this, a
                // follow-up capability_request for the same verb hits
                // persistApprovedCloudCapabilities' idempotency gate (which
                // compares against the resolver snapshot) and silently
                // skips the connection_event — so the user sees the revoke
                // line but no subsequent grant line.
                await clearResolverEntriesForProvider(providerId)
                try? await connectionEventWriter.sendRevoked(providerId: providerId.rawValue, in: conversationId)
            } catch {
                Log.error("Failed to revoke connection grant: \(error.localizedDescription)")
                self.error = error
            }
        }
    }

    private func clearResolverEntriesForProvider(_ providerId: ProviderID) async {
        for subject in CapabilitySubject.allCases {
            for capability in ConnectionCapability.allCases {
                let current = await capabilityResolver.resolution(
                    subject: subject,
                    capability: capability,
                    conversationId: conversationId
                )
                guard current.contains(providerId) else { continue }
                let shrunk = current.subtracting([providerId])
                do {
                    if shrunk.isEmpty {
                        try await capabilityResolver.clearResolution(
                            subject: subject,
                            capability: capability,
                            conversationId: conversationId
                        )
                    } else {
                        try await capabilityResolver.setResolution(
                            shrunk,
                            subject: subject,
                            capability: capability,
                            conversationId: conversationId
                        )
                    }
                } catch {
                    Log.warning("Failed to clear resolver entry for \(providerId.rawValue) (\(subject), \(capability)): \(error.localizedDescription)")
                }
            }
        }
    }

    /// First-link path: run the OAuth flow, then immediately grant the resulting
    /// connection for this conversation so the user's intent ("turn it on for
    /// this convo") completes in one tap. Mirrors what the App Settings list
    /// would do followed by the conversation-info toggle, just chained.
    private func connectAndGrant(serviceId: String, providerId: ProviderID) {
        isConnecting = true
        error = nil
        Task {
            do {
                let connection = try await cloudConnectionManager.connect(serviceId: serviceId)
                try await grantWriter.grantConnection(connection.id, to: conversationId)
                try? await connectionEventWriter.sendGranted(providerId: providerId.rawValue, in: conversationId)
            } catch let oauthError as OAuthError {
                if case .cancelled = oauthError {
                } else {
                    self.error = oauthError
                }
            } catch {
                Log.error("Failed to connect and grant \(serviceId): \(error.localizedDescription)")
                self.error = error
            }
            isConnecting = false
        }
    }

    private func rebuildCloudRows() {
        let activeByServiceId: [String: CloudConnection] = Dictionary(
            connections.map { ($0.serviceId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let granted = grantedConnectionIds

        cloudRows = CloudConnectionServiceCatalog.all
            .filter { SupportedConnections.isSupported(cloudServiceId: $0.id) }
            .map { service in
                let active = activeByServiceId[service.id]
                let isGranted = active.map { granted.contains($0.id) } ?? false
                return CloudRow(
                    serviceId: service.id,
                    info: service,
                    active: active,
                    isGrantedForConversation: isGranted
                )
            }
            .sorted { $0.info.displayName.localizedCaseInsensitiveCompare($1.info.displayName) == .orderedAscending }
    }

    private func refreshDeviceConnections() {
        Task { [self] in
            var items: [DeviceConnection] = []
            for kind in ConnectionKind.allCases where SupportedConnections.isSupported(kind) {
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

            ForEach(viewModel.cloudRows) { row in
                FeatureRowItem(
                    imageName: nil,
                    symbolName: row.info.iconSystemName,
                    title: row.info.displayName,
                    subtitle: row.info.subtitle,
                    iconBackgroundColor: .colorFillMinimal,
                    iconForegroundColor: .colorTextPrimary
                ) {
                    Toggle("", isOn: Binding(
                        get: { row.isOn },
                        set: { _ in viewModel.toggleCloud(row) }
                    ))
                    .labelsHidden()
                    .disabled(viewModel.isConnecting)
                }
            }
        } header: {
            Text("Connections")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.colorTextSecondary)
        }
    }
}
