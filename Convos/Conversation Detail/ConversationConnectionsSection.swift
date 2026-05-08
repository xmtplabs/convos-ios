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
    /// Inbox ids of every agent in this conversation at view-model construction. Each
    /// per-conversation toggle fans out one grant row per agent so the model stays
    /// consistent with the per-agent grant scoping introduced alongside.
    ///
    /// Snapshotted at construction — agents that join the conversation after this view
    /// model is built will not receive grants from subsequent toggles until the model
    /// is recreated. Acceptable because Conversation Info presentations build a fresh
    /// view model each time, but if the membership shifts during the lifetime of an
    /// open settings sheet the user may need to dismiss + reopen for the new agents
    /// to be reachable from the toggle. Tracked as a follow-up if it becomes a real
    /// pain point in multi-agent conversations.
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
            // Snapshot per-agent state once before mutating so we only emit one
            // group-update line per state-change, not one per agent and not one per
            // redundant tap. The snapshot uses any-agent-was-enabled semantics — if at
            // least one agent had the capability, the conversation already showed it on
            // and the user toggling off should fire a single revoked event. The
            // `where !anyWasEnabled` clause short-circuits the loop once any agent
            // reports enabled.
            var anyWasEnabled = false
            for agent in agents where !anyWasEnabled {
                anyWasEnabled = await enablementStore.isEnabled(
                    kind: kind,
                    capability: .read,
                    conversationId: conversationId,
                    grantedToInboxId: agent
                )
            }
            for agent in agents {
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
                // Credit the first agent so the rendered text reads as
                // "<agent name> has access to …" instead of a subject-less phrase.
                // With multiple agents this is imprecise — every agent really did get
                // the grant — but the chat shows one event per state change, and one
                // representative actor matches the prior single-actor display.
                let representativeAgent = agents.first
                if newValue {
                    try? await connectionEventWriter.sendGranted(
                        providerId: "device.\(kind.rawValue)",
                        capability: nil,
                        grantedToInboxId: representativeAgent,
                        in: conversationId
                    )
                } else {
                    try? await connectionEventWriter.sendRevoked(
                        providerId: "device.\(kind.rawValue)",
                        capability: nil,
                        grantedToInboxId: representativeAgent,
                        in: conversationId
                    )
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
        let agents = agentInboxIds
        guard !agents.isEmpty else { return }
        Task {
            var anyWritten = false
            for agent in agents {
                do {
                    try await grantWriter.grantConnection(connectionId, to: conversationId, grantedToInboxId: agent)
                    anyWritten = true
                } catch {
                    Log.error("Failed to grant connection \(connectionId) to \(agent): \(error.localizedDescription)")
                    self.error = error
                }
            }
            if anyWritten {
                try? await connectionEventWriter.sendGranted(
                    providerId: providerId.rawValue,
                    capability: nil,
                    grantedToInboxId: agents.first,
                    in: conversationId
                )
            }
        }
    }

    private func revokeGrant(connectionId: String, providerId: ProviderID) {
        let agents = agentInboxIds
        guard !agents.isEmpty else { return }
        Task {
            var anyRemoved = false
            for agent in agents {
                do {
                    try await grantWriter.revokeGrant(connectionId: connectionId, from: conversationId, grantedToInboxId: agent)
                    anyRemoved = true
                } catch {
                    Log.error("Failed to revoke grant \(connectionId) from \(agent): \(error.localizedDescription)")
                    self.error = error
                }
            }
            if anyRemoved {
                // Order matches CloudConnectionManager.postRevocationSideEffects:
                // post the user-visible group-update line first, then drop the
                // provider from every (subject, verb, agent) row scoped to this
                // conversation. Resolver-cleanup is what unblocks
                // persistApprovedCloudCapabilities' idempotency gate so a
                // follow-up capability_request approval re-emits its own
                // group-update line. Revoke text is a complete sentence
                // ("Calendar connection removed") so it reads fine without an actor —
                // we leave grantedToInboxId nil to keep the message conversation-level.
                try? await connectionEventWriter.sendRevoked(
                    providerId: providerId.rawValue,
                    capability: nil,
                    grantedToInboxId: nil,
                    in: conversationId
                )
                await clearResolverEntriesForProvider(providerId, agents: agents)
            }
        }
    }

    private func clearResolverEntriesForProvider(_ providerId: ProviderID, agents: [String]) async {
        for subject in CapabilitySubject.allCases {
            for capability in ConnectionCapability.allCases {
                for agent in agents {
                    let current = await capabilityResolver.resolution(
                        subject: subject,
                        capability: capability,
                        conversationId: conversationId,
                        grantedToInboxId: agent
                    )
                    guard current.contains(providerId) else { continue }
                    let shrunk = current.subtracting([providerId])
                    do {
                        if shrunk.isEmpty {
                            try await capabilityResolver.clearResolution(
                                subject: subject,
                                capability: capability,
                                conversationId: conversationId,
                                grantedToInboxId: agent
                            )
                        } else {
                            try await capabilityResolver.setResolution(
                                shrunk,
                                subject: subject,
                                capability: capability,
                                conversationId: conversationId,
                                grantedToInboxId: agent
                            )
                        }
                    } catch {
                        Log.warning("Failed to clear resolver entry for \(providerId.rawValue) (\(subject), \(capability), \(agent)): \(error.localizedDescription)")
                    }
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
                var anyWritten = false
                for agent in agents {
                    do {
                        try await grantWriter.grantConnection(connection.id, to: conversationId, grantedToInboxId: agent)
                        anyWritten = true
                    } catch {
                        Log.error("Failed to grant fresh connection \(connection.id) to \(agent): \(error.localizedDescription)")
                        self.error = error
                    }
                }
                if anyWritten {
                    try? await connectionEventWriter.sendGranted(
                        providerId: providerId.rawValue,
                        capability: nil,
                        grantedToInboxId: agents.first,
                        in: conversationId
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
                // The toggle reads on for the conversation if any agent has it enabled —
                // matches the per-conversation UX even though storage is per-agent.
                // The `where !isReadEnabled` clause short-circuits once any agent reports
                // enabled.
                var isReadEnabled = false
                for agent in agents where !isReadEnabled {
                    isReadEnabled = await self.enablementStore.isEnabled(
                        kind: kind,
                        capability: .read,
                        conversationId: self.conversationId,
                        grantedToInboxId: agent
                    )
                }
                var hasWrite = false
                if !isReadEnabled {
                    for agent in agents {
                        for capability in ConnectionCapability.allCases where capability.isWrite {
                            if await self.enablementStore.isEnabled(
                                kind: kind,
                                capability: capability,
                                conversationId: self.conversationId,
                                grantedToInboxId: agent
                            ) {
                                hasWrite = true
                                break
                            }
                        }
                        if hasWrite { break }
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
