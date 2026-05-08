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
    /// Inbox ids of every agent in this conversation, snapshotted at construction.
    /// Per-conversation toggles fan out one grant row per agent.
    private let agentInboxIds: [String]
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
        agentInboxIds: [String],
        cloudConnectionManager: any CloudConnectionManagerProtocol,
        cloudConnectionRepository: any CloudConnectionRepositoryProtocol,
        grantWriter: any CloudConnectionGrantWriterProtocol,
        connectionEventWriter: any ConnectionEventWriterProtocol,
        enablementStore: any EnablementStore,
        capabilityResolver: any CapabilityResolver
    ) {
        self.conversationId = conversationId
        self.agentInboxIds = agentInboxIds
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
        let agents = agentInboxIds
        // No agents → nothing to grant or revoke against. Bail before mutating local
        // state so the toggle doesn't visually flip while storage stays untouched.
        guard !agents.isEmpty else { return }
        let newValue = !deviceConnections[index].isEnabled
        deviceConnections[index] = DeviceConnection(kind: kind, isEnabled: newValue)
        Task {
            // any-agent-was-enabled snapshot taken before mutation: if at least one
            // agent had any capability for this kind, the conversation already
            // showed the toggle on, and toggling off should fire a single revoked
            // event. Mirrors `refreshDeviceConnections`'s display semantics
            // (read or any write) so the two paths can't drift — checking only
            // `.read` here silently dropped the revoke event when the user revoked
            // a write-only kind.
            let anyWasEnabled = await isAnyCapabilityEnabled(kind: kind, agents: agents)
            await forEachAgent(agents: agents, label: "set enablement \(kind.rawValue)") { agent in
                for capability in ConnectionCapability.allCases {
                    await enablementStore.setEnabled(
                        newValue,
                        kind: kind,
                        capability: capability,
                        conversationId: conversationId,
                        grantedToInboxId: agent
                    )
                }
            }
            if newValue != anyWasEnabled {
                await postRepresentativeEvent(
                    granted: newValue,
                    providerId: "device.\(kind.rawValue)",
                    representative: agents.first
                )
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
        let agents = agentInboxIds
        guard !agents.isEmpty else { return }
        Task {
            let written = await forEachAgent(agents: agents, label: "grant \(connectionId)") { agent in
                try await grantWriter.grantConnection(connectionId, to: conversationId, grantedToInboxId: agent)
            }
            if !written.isEmpty {
                await postRepresentativeEvent(granted: true, providerId: providerId.rawValue, representative: agents.first)
            }
        }
    }

    private func revokeGrant(connectionId: String, providerId: ProviderID) {
        let agents = agentInboxIds
        guard !agents.isEmpty else { return }
        Task {
            let removed = await forEachAgent(agents: agents, label: "revoke \(connectionId)") { agent in
                try await grantWriter.revokeGrant(connectionId: connectionId, from: conversationId, grantedToInboxId: agent)
            }
            if !removed.isEmpty {
                // Order matches CloudConnectionManager.postRevocationSideEffects:
                // post the user-visible group-update line first, then drop the
                // provider from every (subject, verb, agent) row in this conversation.
                // Resolver-cleanup is what unblocks persistApprovedCloudCapabilities'
                // idempotency gate so a follow-up capability_request approval re-emits
                // its own group-update line. Revoke text is a complete sentence
                // ("Calendar connection removed") so we keep grantedToInboxId nil and
                // render it conversation-level.
                try? await connectionEventWriter.sendRevoked(
                    providerId: providerId.rawValue,
                    capability: nil,
                    grantedToInboxId: nil,
                    in: conversationId
                )
                do {
                    try await capabilityResolver.removeProvider(providerId, fromConversation: conversationId)
                } catch {
                    Log.warning("Failed to clear resolver entries for \(providerId.rawValue): \(error.localizedDescription)")
                }
            }
        }
    }

    /// First-link path: run the OAuth flow, then immediately grant the resulting
    /// connection for this conversation so the user's intent ("turn it on for
    /// this convo") completes in one tap. Mirrors what the App Settings list
    /// would do followed by the conversation-info toggle, just chained — fanning
    /// out the grant across every agent currently in the conversation.
    private func connectAndGrant(serviceId: String, providerId: ProviderID) {
        let agents = agentInboxIds
        guard !agents.isEmpty else { return }
        isConnecting = true
        error = nil
        Task {
            do {
                let connection = try await cloudConnectionManager.connect(serviceId: serviceId)
                let written = await forEachAgent(
                    agents: agents,
                    label: "grant fresh connection \(connection.id)"
                ) { agent in
                    try await grantWriter.grantConnection(connection.id, to: conversationId, grantedToInboxId: agent)
                }
                if !written.isEmpty {
                    await postRepresentativeEvent(
                        granted: true,
                        providerId: providerId.rawValue,
                        representative: agents.first
                    )
                }
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
        let agents = agentInboxIds
        Task { [self] in
            var items: [DeviceConnection] = []
            for kind in ConnectionKind.allCases where SupportedConnections.isSupported(kind) {
                let isEnabled = await self.isAnyCapabilityEnabled(kind: kind, agents: agents)
                items.append(DeviceConnection(kind: kind, isEnabled: isEnabled))
            }
            await MainActor.run {
                self.deviceConnections = items.sorted { $0.kind.displayName < $1.kind.displayName }
            }
        }
    }

    /// True when at least one agent has any capability enabled for `kind`. The toggle
    /// reads on for the conversation under that condition, matching the per-conversation
    /// UX even though storage is per-agent. Shared between the display path
    /// (`refreshDeviceConnections`) and the toggle-off snapshot in
    /// `toggleDeviceConnection` so the two can't drift on which capabilities count.
    private func isAnyCapabilityEnabled(kind: ConnectionKind, agents: [String]) async -> Bool {
        for agent in agents {
            for capability in ConnectionCapability.allCases {
                let enabled = await enablementStore.isEnabled(
                    kind: kind,
                    capability: capability,
                    conversationId: conversationId,
                    grantedToInboxId: agent
                )
                guard !enabled else { return true }
            }
        }
        return false
    }

    /// Run `body` once per agent. Logs and stores `self.error` on per-agent failures
    /// without short-circuiting the loop, returns the agents the body completed for.
    /// Caller decides whether the resulting list is "good enough" to emit a
    /// representative connection_event. `Void` body returns `[String]` of completed
    /// agents.
    @discardableResult
    private func forEachAgent(
        agents: [String],
        label: String,
        _ body: (String) async throws -> Void
    ) async -> [String] {
        var succeeded: [String] = []
        for agent in agents {
            do {
                try await body(agent)
                succeeded.append(agent)
            } catch {
                Log.error("\(label) failed for \(agent): \(error.localizedDescription)")
                self.error = error
            }
        }
        return succeeded
    }

    /// Post a single conversation-level connection_event crediting one representative
    /// agent. The chat shows one event per state change with the agent's name, instead
    /// of a subject-less phrase ("has access to …"); with multiple agents this is
    /// imprecise — every agent really did get the grant — but matches the prior
    /// single-actor display.
    private func postRepresentativeEvent(
        granted: Bool,
        providerId: String,
        representative: String?
    ) async {
        if granted {
            try? await connectionEventWriter.sendGranted(
                providerId: providerId,
                capability: nil,
                grantedToInboxId: representative,
                in: conversationId
            )
        } else {
            try? await connectionEventWriter.sendRevoked(
                providerId: providerId,
                capability: nil,
                grantedToInboxId: representative,
                in: conversationId
            )
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
