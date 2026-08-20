import SwiftUI
import UIKit

struct GrokBotConnectionSetupView: View {
    let onConnected: () -> Void

    @State private var configuration: GrokBotConnectionConfiguration?
    @State private var agents: [GrokBotAgent]
    @State private var enabledAgentIds: Set<String>
    @State private var bridgeURL: String
    @State private var sharesYourSpaceContext: Bool
    @State private var showsAdvancedSetup: Bool = false
    @State private var isWorking: Bool = false
    @State private var isWaitingForComputer: Bool = false
    @State private var copiedPairingToken: Bool = false
    @State private var connectionError: String?

    private let client: GrokBotBridgeClient = .init()

    init(onConnected: @escaping () -> Void) {
        self.onConnected = onConnected
        let existing = GrokBotConnectionStore.configuration()
        _configuration = State(initialValue: existing)
        _agents = State(initialValue: existing?.agents ?? [])
        _enabledAgentIds = State(initialValue: existing?.enabledAgentIds ?? [])
        _bridgeURL = State(
            initialValue: existing?.bridgeURL.absoluteString
                ?? GrokBotConnectionConfiguration.defaultBridgeURL.absoluteString
        )
        _sharesYourSpaceContext = State(initialValue: existing?.sharesYourSpaceContext ?? true)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                introduction
                if configuration == nil {
                    connectionPromise
                } else if agents.isEmpty {
                    waitingState
                } else {
                    agentPicker
                    contextBoundary
                }
                advancedSetup
                if let connectionError {
                    Label(connectionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step5x)
            .padding(.top, DesignConstants.Spacing.step5x)
            .padding(.bottom, 120)
        }
        .background(.colorBackgroundSurfaceless)
        .navigationTitle("Connect Grok Bot")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            primaryAction
        }
        .task {
            guard configuration != nil, agents.isEmpty else { return }
            await refreshAgents()
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: ExternalAgentProvider.grokBot.symbolName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 68, height: 68)
                .background(ExternalAgentProvider.grokBot.tint, in: .circle)

            Text("Bring your Grok Bot agents home")
                .font(.largeTitle.bold())
                .tracking(-0.8)
                .foregroundStyle(.colorTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Connect your Grok Bot computer once, then add Hamilton, CTO, Travel Planner, or as many named agents as you want. Each one gets its own private harness in Convos.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectionPromise: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            promiseRow(
                symbol: "desktopcomputer",
                title: "One computer connection",
                detail: "Your Grok Bot computer reaches out to Convos. The phone never connects to a local port."
            )
            promiseRow(
                symbol: "person.2.fill",
                title: "Many named Grokbots",
                detail: "Every agent you enable appears separately, and you can come back to add more at any time."
            )
            promiseRow(
                symbol: "lock.fill",
                title: "Private by default",
                detail: "These agents stay in your private lane. Results are saved or shared only when you choose."
            )
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
    }

    private var waitingState: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
                ProgressView()
                    .controlSize(.regular)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text(isWaitingForComputer ? "Waiting for your Grok Bot computer" : "Looking for your Grokbots")
                        .font(.headline)
                        .foregroundStyle(.colorTextPrimary)
                    Text("Copy this connection's pairing token and paste it into your Grok Bot relay. Once the relay checks in, every available agent will appear here by name.")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: copyPairingToken) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Image(systemName: copiedPairingToken ? "checkmark" : "doc.on.doc")
                    Text(copiedPairingToken ? "Pairing token copied" : "Copy pairing token")
                    Spacer(minLength: DesignConstants.Spacing.step2x)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .frame(minHeight: 52)
                .background(.colorFillMinimal, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("grokbot-copy-pairing-token-button")

            Label("Treat this token like a password. No webhook or inbound port is used.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
        .accessibilityIdentifier("grokbot-waiting-for-computer")
    }

    private func copyPairingToken() {
        guard let token = configuration?.sessionToken else { return }
        UIPasteboard.general.string = token
        copiedPairingToken = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copiedPairingToken = false
        }
    }

    private var agentPicker: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("Choose your Grokbots")
                    .font(.title2.bold())
                    .foregroundStyle(.colorTextPrimary)
                Text("Each selected agent gets its own name in Your Space and every Talk to selector.")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                    agentRow(agent)
                    if index < agents.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))

            Button {
                Task { await refreshAgents() }
            } label: {
                Label("Check for new Grokbots", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .disabled(isWorking)
            .accessibilityIdentifier("grokbot-refresh-agents-button")
        }
    }

    private func agentRow(_ agent: GrokBotAgent) -> some View {
        Button {
            if enabledAgentIds.contains(agent.id) {
                enabledAgentIds.remove(agent.id)
            } else {
                enabledAgentIds.insert(agent.id)
            }
        } label: {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                Image(systemName: "desktopcomputer")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 40)
                    .background(ExternalAgentProvider.grokBot.tint, in: .circle)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(agent.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    if let detail = agent.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.colorTextSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: DesignConstants.Spacing.step2x)

                Image(systemName: enabledAgentIds.contains(agent.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(enabledAgentIds.contains(agent.id) ? .colorLava : .colorTextTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 64)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.name)
        .accessibilityValue(enabledAgentIds.contains(agent.id) ? "Selected" : "Not selected")
        .accessibilityHint("Adds or removes this Grok Bot from your private agent selectors")
        .accessibilityIdentifier("grokbot-agent-\(agent.id)")
    }

    private var contextBoundary: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Toggle(isOn: $sharesYourSpaceContext) {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text("Use Your Space context")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Text("Send the current private briefing and bounded context snapshot with each request. Turn this off to send only what you type.")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(.colorLava)

            Label(
                "The session credential stays in the iPhone Keychain. Your computer's gateway token never comes to Convos.",
                systemImage: "lock.fill"
            )
            .font(.caption)
            .foregroundStyle(.colorTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advancedSetup: some View {
        DisclosureGroup("Advanced", isExpanded: $showsAdvancedSetup) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Text("Grok Bot bridge")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
                TextField("https://…", text: $bridgeURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .padding(DesignConstants.Spacing.step3x)
                    .background(.colorFillMinimal, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
                Text("Change this only if you host your own Grok Bot relay bridge.")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.top, DesignConstants.Spacing.step3x)
        }
        .font(.body.weight(.semibold))
    }

    private var primaryAction: some View {
        Button {
            Task { await performPrimaryAction() }
        } label: {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                if isWorking {
                    ProgressView().tint(.colorTextPrimaryInverted)
                } else {
                    Image(systemName: primaryActionSymbol)
                }
                Text(primaryActionTitle)
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.colorTextPrimaryInverted)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(.colorFillPrimary, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
        }
        .buttonStyle(.plain)
        .disabled(isWorking || (configuration != nil && !agents.isEmpty && enabledAgentIds.isEmpty))
        .opacity(configuration != nil && !agents.isEmpty && enabledAgentIds.isEmpty ? 0.45 : 1)
        .padding(.horizontal, DesignConstants.Spacing.step5x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .background(.bar)
        .accessibilityIdentifier("grokbot-primary-action")
    }

    private var primaryActionTitle: String {
        if isWorking {
            return configuration == nil ? "Connecting…" : "Checking for Grokbots…"
        }
        if configuration == nil {
            return "Connect"
        }
        if agents.isEmpty {
            return "Check for Grokbots"
        }
        return "Add \(enabledAgentIds.count) Grokbot\(enabledAgentIds.count == 1 ? "" : "s")"
    }

    private var primaryActionSymbol: String {
        if configuration == nil { return "link" }
        if agents.isEmpty { return "arrow.clockwise" }
        return "checkmark"
    }

    private func promiseRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(ExternalAgentProvider.grokBot.tint)
                .frame(width: 32, height: 32)
                .background(ExternalAgentProvider.grokBot.tint.opacity(0.1), in: .circle)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @MainActor
    private func performPrimaryAction() async {
        guard !isWorking else { return }
        if configuration == nil {
            await connect()
        } else if agents.isEmpty {
            await refreshAgents()
        } else {
            await saveSelection()
        }
    }

    @MainActor
    private func connect() async {
        isWorking = true
        connectionError = nil
        defer { isWorking = false }
        do {
            let created = try await client.createSession(
                bridgeURLText: bridgeURL,
                sharesYourSpaceContext: sharesYourSpaceContext
            )
            try GrokBotConnectionStore.save(created)
            configuration = created
            await refreshAgents()
        } catch {
            connectionError = error.localizedDescription
        }
    }

    @MainActor
    private func refreshAgents() async {
        guard var current = configuration else { return }
        isWorking = true
        connectionError = nil
        defer { isWorking = false }
        do {
            current = try current.updating(
                sharesYourSpaceContext: sharesYourSpaceContext,
                bridgeURLText: bridgeURL
            )
            switch try await client.fetchAgents(configuration: current) {
            case .waitingForComputer:
                isWaitingForComputer = true
                try GrokBotConnectionStore.save(current)
                configuration = current
            case .available(let discovered):
                isWaitingForComputer = false
                agents = discovered
                let discoveredIds = Set(discovered.map(\.id))
                let stillEnabled = enabledAgentIds.intersection(discoveredIds)
                enabledAgentIds = stillEnabled.isEmpty ? discoveredIds : stillEnabled
                current = try current.updating(agents: discovered, enabledAgentIds: enabledAgentIds)
                try GrokBotConnectionStore.save(current)
                configuration = current
            }
        } catch {
            connectionError = error.localizedDescription
        }
    }

    @MainActor
    private func saveSelection() async {
        guard let current = configuration else { return }
        isWorking = true
        connectionError = nil
        defer { isWorking = false }
        do {
            let updated = try current.updating(
                agents: agents,
                enabledAgentIds: enabledAgentIds,
                sharesYourSpaceContext: sharesYourSpaceContext,
                bridgeURLText: bridgeURL
            )
            try GrokBotConnectionStore.save(updated)
            configuration = updated
            onConnected()
        } catch {
            connectionError = error.localizedDescription
        }
    }
}
