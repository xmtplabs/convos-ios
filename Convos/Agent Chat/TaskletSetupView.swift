import ConvosCore
import SwiftUI

struct TaskletSetupView: View {
    let dependencies: AgentRelayDependencies
    let session: any SessionManagerProtocol
    @State private var viewModel: AgentSetupViewModel
    @State private var webhookURL: String = ""
    @State private var showingDisconnectConfirmation: Bool = false

    init(dependencies: AgentRelayDependencies, session: any SessionManagerProtocol) {
        self.dependencies = dependencies
        self.session = session
        _viewModel = State(initialValue: AgentSetupViewModel(provider: .tasklet, dependencies: dependencies))
    }

    var body: some View {
        Form {
            previewBackendSection
            instructionSection
            webhookSection
            privacySection
            connectionSection
        }
        .navigationTitle("Connect Tasklet")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadExistingConnection() }
        .confirmationDialog("Disconnect Tasklet?", isPresented: $showingDisconnectConfirmation) {
            let action = { viewModel.disconnect() }
            Button("Disconnect", role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your agent transcript stays on this iPhone.")
        }
    }

    @ViewBuilder
    private var previewBackendSection: some View {
        if ConfigManager.shared.isAgentRelayPreviewBuild {
            Section {
                Text(AgentSetupCopy.previewBackendNote)
            }
        }
    }

    @ViewBuilder
    private var instructionSection: some View {
        let instruction: String = AgentSetupCopy.taskletInstruction(mcpURL: dependencies.mcpURL)
        Section("Set up Tasklet") {
            Text("Paste this instruction into the agent's thread.")
            Text(instruction)
            AgentSetupCopyButton(title: "Copy setup instruction", text: instruction)
        }
    }

    @ViewBuilder
    private var webhookSection: some View {
        Section("Paste back the webhook URL") {
            TextField("Webhook URL", text: $webhookURL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
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
                _ = Task { await viewModel.connect(webhookURLText: webhookURL, secret: "") }
            }
            Button("Connect", action: connectAction)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(viewModel.isBusy)
            AgentConnectionTestStatusView(state: viewModel.state, provider: .tasklet)
            if viewModel.isConnected {
                NavigationLink("Open agent chat") {
                    AgentChatView(provider: .tasklet, dependencies: dependencies, session: session)
                }
                let disconnectAction = { showingDisconnectConfirmation = true }
                Button("Disconnect", role: .destructive, action: disconnectAction)
            }
        }
    }

    private func loadExistingConnection() {
        guard let connection = try? dependencies.connectionStore.load(provider: .tasklet) else { return }
        webhookURL = connection.webhookURL.absoluteString
    }
}
