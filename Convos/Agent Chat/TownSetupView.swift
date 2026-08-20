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
            webhookSection
            returnToolSection
            instructionSection
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
            Text("Your agent transcript stays on this iPhone.")
        }
    }

    @ViewBuilder
    private var webhookSection: some View {
        Section("Turn on its webhook") {
            Text("In Town, open the routine you want in Convos, enable its webhook trigger, copy the webhook URL and secret into Convos.")
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
    private var returnToolSection: some View {
        Section("Give Town the return tool") {
            Text("Add this custom MCP server to the routine and enable return_result.")
            Text(dependencies.mcpURL.absoluteString)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
            AgentSetupCopyButton(title: "Copy MCP URL", text: dependencies.mcpURL.absoluteString)
        }
    }

    @ViewBuilder
    private var instructionSection: some View {
        Section("Tell the routine how to reply") {
            Text(AgentSetupCopy.townInstruction)
            AgentSetupCopyButton(title: "Copy instruction", text: AgentSetupCopy.townInstruction)
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
                NavigationLink("Open agent chat") {
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
