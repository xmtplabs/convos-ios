import ConvosCore
import SwiftUI

struct TownSetupView: View {
    let dependencies: AgentRelayDependencies
    let session: any SessionManagerProtocol
    @State private var viewModel: AgentSetupViewModel
    @State private var webhookURL: String = ""
    @State private var bearerSecret: String = ""
    @State private var showingDisconnectConfirmation: Bool = false

    init(dependencies: AgentRelayDependencies, session: any SessionManagerProtocol) {
        self.dependencies = dependencies
        self.session = session
        _viewModel = State(initialValue: AgentSetupViewModel(provider: .town, dependencies: dependencies))
    }

    var body: some View {
        Form {
            previewBackendSection
            mcpServerSection
            routineSection
            webhookSection
            privacySection
            connectionSection
        }
        .navigationTitle("Connect Town")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadExistingConnection() }
        .confirmationDialog("Disconnect Town?", isPresented: $showingDisconnectConfirmation) {
            let action = { viewModel.disconnect() }
            Button("Disconnect", role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your agent chats stay on this iPhone.")
        }
    }

    @ViewBuilder
    private var previewBackendSection: some View {
        if ConfigManager.shared.isAgentRelayPreviewBackend {
            Section {
                Text(AgentSetupCopy.previewBackendNote)
            }
        }
    }

    @ViewBuilder
    private var mcpServerSection: some View {
        Section("Create the MCP server") {
            Text("In Town, go to Powers > Integrations > \"Add MCP server\". Name it Convos, select \"No auth\", and paste this MCP URL from Convos.")
            Text(dependencies.mcpURL.absoluteString)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
            AgentSetupCopyButton(title: "Copy MCP URL", text: dependencies.mcpURL.absoluteString)
        }
    }

    @ViewBuilder
    private var routineSection: some View {
        Section("Create the routine") {
            Text("Paste these instructions into a new Town routine.")
            Text(AgentSetupCopy.townInstruction)
            AgentSetupCopyButton(title: "Copy instructions", text: AgentSetupCopy.townInstruction)
        }
    }

    @ViewBuilder
    private var webhookSection: some View {
        Section("Enable the webhook") {
            Text("In Town, enable the routine's webhook trigger, then copy the webhook URL and bearer secret it shows into these fields in Convos.")
            TextField("Webhook URL", text: $webhookURL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("Bearer secret", text: $bearerSecret)
                .textContentType(.password)
            if let message = viewModel.validationMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var privacySection: some View {
        Section {
            AgentCredentialNote()
            Text(AgentSetupCopy.notificationNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            let connectAction: @MainActor () -> Void = {
                _ = Task { await viewModel.connect(webhookURLText: webhookURL, secret: bearerSecret) }
            }
            Button("Connect", action: connectAction)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(viewModel.isBusy)
            AgentConnectionTestStatusView(state: viewModel.state, provider: .town)
            if viewModel.isConnected {
                NavigationLink("Open Relay") {
                    AgentChatView(provider: .town, dependencies: dependencies, session: session)
                }
                let disconnectAction = { showingDisconnectConfirmation = true }
                Button("Disconnect", role: .destructive, action: disconnectAction)
            }
        }
    }

    private func loadExistingConnection() {
        guard let connection = try? dependencies.connectionStore.load(provider: .town) else { return }
        webhookURL = connection.webhookURL.absoluteString
        if case .bearer(let secret) = connection.auth {
            bearerSecret = secret
        }
    }
}
