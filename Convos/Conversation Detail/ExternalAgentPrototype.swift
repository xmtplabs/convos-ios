import ConvosComposer
import Foundation
import SwiftUI

enum ExternalAgentProvider: String, CaseIterable, Hashable, Identifiable {
    case codex
    case town
    case tasklet
    case grokBot
    case claudeCode
    case hermes
    case openClaw
    case connectMCP

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .town: "Town"
        case .tasklet: "Tasklet"
        case .claudeCode: "Claude Code"
        case .hermes: "Hermes"
        case .openClaw: "OpenClaw"
        case .grokBot: "Grok Bot"
        case .connectMCP: "Connect MCP"
        }
    }

    var shortDescription: String {
        switch self {
        case .codex: "OpenAI coding agent"
        case .town: "Your Town agent and routines"
        case .tasklet: "Your always-on cloud agent"
        case .claudeCode: "Anthropic coding agent"
        case .hermes: "Your self-hosted Hermes agent"
        case .openClaw: "Your OpenClaw gateway"
        case .grokBot: "Multiple agents from your Grok Bot computer"
        case .connectMCP: "Coming soon"
        }
    }

    var chatSubtitle: String {
        switch self {
        case .codex: "Connected to your Mac · Private desktop collaborator"
        case .town: "Live · Your Town routine"
        case .tasklet: "Live · Your Tasklet agent"
        case .claudeCode: "Connected demo · Private desktop collaborator"
        case .hermes: "Paired gateway demo · Scoped to this convo"
        case .openClaw: "Paired gateway demo · Scoped to this convo"
        case .grokBot: "Live · Private agent on your computer"
        case .connectMCP: "Coming soon · Bring any compatible agent"
        }
    }

    /// Short, flexible descriptor for the agent switcher rows and the dock
    /// subtitle. Casual services carry a personal agent name in the title and
    /// read as "<Service> agent" here; techy services put the product name in
    /// the title and the platform or company here. The two-line row then stays
    /// natural for both - "Ray / Town agent" and "Codex / Open AI" - instead of
    /// forcing an "... agent" suffix onto everything.
    var switcherSubtitle: String {
        switch self {
        case .codex: "Open AI"
        case .town: "Town agent"
        case .tasklet: "Tasklet agent"
        case .claudeCode: "Anthropic"
        case .hermes: "Self-hosted gateway"
        case .openClaw: "OpenClaw gateway"
        case .grokBot: "Grok Bot agent"
        case .connectMCP: "Connect MCP"
        }
    }

    var symbolName: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .town: "building.2.crop.circle.fill"
        case .tasklet: "checkmark.square.fill"
        case .claudeCode: "terminal.fill"
        case .hermes: "h.circle.fill"
        case .openClaw: "antenna.radiowaves.left.and.right"
        case .grokBot: "desktopcomputer"
        case .connectMCP: "point.3.connected.trianglepath.dotted"
        }
    }

    var tint: Color {
        switch self {
        case .codex: Color(red: 0.08, green: 0.08, blue: 0.09)
        case .town: Color(red: 0.10, green: 0.37, blue: 0.28)
        case .tasklet: Color(red: 0.30, green: 0.23, blue: 0.76)
        case .claudeCode: Color(red: 0.72, green: 0.36, blue: 0.20)
        case .hermes: Color(red: 0.23, green: 0.38, blue: 0.74)
        case .openClaw: Color(red: 0.77, green: 0.17, blue: 0.13)
        case .grokBot: Color(red: 0.12, green: 0.12, blue: 0.14)
        case .connectMCP: Color(red: 0.24, green: 0.27, blue: 0.31)
        }
    }

    var connectionTitle: String {
        switch self {
        case .codex: "Pair Codex from your desktop"
        case .town: "Connect your Town agent"
        case .tasklet: "Connect your Tasklet agent"
        case .claudeCode: "Pair Claude Code from your desktop"
        case .hermes: "Connect your Hermes gateway"
        case .openClaw: "Connect your OpenClaw gateway"
        case .grokBot: "Connect your Grok Bot agents"
        case .connectMCP: "Connect MCP is coming soon"
        }
    }

    var connectionExplanation: String {
        switch self {
        case .codex:
            "Convos connects to Codex app-server on your Mac. Your existing ChatGPT sign-in, Codex history, tools, and workspace stay on the computer."
        case .town:
            "Convos calls your Town routine through its authenticated webhook. Town returns the finished message and links through a one-request MCP capability."
        case .tasklet:
            "Convos sends work to your Tasklet agent through a private webhook. " +
                "Tasklet uses its approved memory, connections, and tools, then returns the finished message and links through a one-request MCP capability."
        case .claudeCode:
            "Convos would pair with Claude Code on your computer after you authenticate with Anthropic, Claude Pro or Max, Bedrock, or Vertex AI."
        case .hermes:
            "Hermes exposes an OpenAI-compatible API server. Convos would pair to that gateway with its URL and API server key."
        case .openClaw:
            "Convos would become an approved OpenClaw device, connecting to its WebSocket gateway with a token and explicit operator scopes."
        case .grokBot:
            "Connect your Grok Bot computer once, then choose as many named agents as you want. Each selected agent becomes its own private harness in Convos."
        case .connectMCP:
            "Connect MCP will let you bring an MCP-compatible personal agent to Convos with an explicit private context boundary."
        }
    }

    var requirements: [ExternalAgentConnectionRequirement] {
        switch self {
        case .codex:
            [
                .init(symbol: "desktopcomputer", title: "Codex app-server", detail: "Runs on the Mac where Codex already has your sign-in and tools."),
                .init(symbol: "key.fill", title: "Capability token", detail: "A revocable token protects this connection and stays in the iPhone Keychain."),
                .init(symbol: "folder.badge.gearshape", title: "Approved workspace", detail: "Choose the Mac project where Codex may read and make things."),
            ]
        case .town:
            [
                .init(symbol: "bolt.horizontal.circle.fill", title: "Routine webhook", detail: "The HTTPS URL and bearer secret from the Town routine you want in Convos."),
                .init(symbol: "point.3.connected.trianglepath.dotted", title: "Convos return MCP", detail: "A narrow tool Town uses to return one finished result to its waiting request."),
                .init(symbol: "lock.fill", title: "Private context choice", detail: "Send Your Space context only when you enable it; saving and sharing remain your choice."),
            ]
        case .tasklet:
            [
                .init(symbol: "bolt.horizontal.circle.fill", title: "Webhook automation", detail: "A private Tasklet webhook starts work inside the agent you choose."),
                .init(symbol: "point.3.connected.trianglepath.dotted", title: "Convos return MCP", detail: "A narrow tool returns one finished result and useful links to the waiting request."),
                .init(symbol: "checkmark.shield.fill", title: "Tasklet permissions", detail: "The agent keeps the memory, connections, tools, and approval rules you configured in Tasklet."),
            ]
        case .claudeCode:
            [
                .init(symbol: "desktopcomputer", title: "Convos desktop bridge", detail: "Pairs this convo to the machine running Claude Code."),
                .init(symbol: "person.crop.circle.badge.checkmark", title: "Claude authorization", detail: "Use Anthropic Console, Claude Pro or Max, Bedrock, or Vertex."),
                .init(symbol: "folder.badge.gearshape", title: "Approved workspace", detail: "Choose the project and tools available to this convo."),
            ]
        case .hermes:
            [
                .init(symbol: "server.rack", title: "Gateway address", detail: "The reachable Hermes API server running on your machine or server."),
                .init(symbol: "key.fill", title: "API server key", detail: "A revocable key created for this Convos connection."),
                .init(symbol: "checkmark.shield.fill", title: "Tool boundary", detail: "Hermes keeps only the tools you approve enabled."),
            ]
        case .openClaw:
            [
                .init(symbol: "point.3.connected.trianglepath.dotted", title: "Gateway URL", detail: "The secure WebSocket address for your OpenClaw gateway."),
                .init(symbol: "key.fill", title: "Gateway token", detail: "A revocable token plus device pairing for this connection."),
                .init(symbol: "checkmark.shield.fill", title: "Operator scopes", detail: "Read and write scopes limited to the access you choose here."),
            ]
        case .grokBot:
            [
                .init(symbol: "desktopcomputer", title: "One computer relay", detail: "Your Grok Bot computer reaches out to Convos without opening an inbound port."),
                .init(symbol: "person.2.fill", title: "Named Grokbots", detail: "Hamilton, CTO, Travel Planner, and every enabled agent stay independently selectable."),
                .init(symbol: "checkmark.shield.fill", title: "Private context choice", detail: "Only the prompt and optional Your Space snapshot you approve are sent."),
            ]
        case .connectMCP:
            [
                .init(symbol: "network", title: "Remote MCP server", detail: "A secure MCP endpoint for the personal agent you already use."),
                .init(symbol: "key.fill", title: "Private authorization", detail: "A revocable credential stored securely on this device."),
                .init(symbol: "checkmark.shield.fill", title: "Explicit context", detail: "You choose what the agent can read and what comes back to a convo."),
            ]
        }
    }

    var welcomeMessage: String {
        switch self {
        case .codex: "I’m connected to Codex on your Mac. Point me at Your Space context or describe what you want to build, and I’ll keep the work inside the workspace you chose."
        case .town: "Your Town routine is live in Convos. Ask me to work with your Town memory and tools; my result comes back here for you to save or share."
        case .tasklet: "Your Tasklet agent is live in Convos. Ask me to use its memory, connections, and tools; the finished result comes back here for you to save or share."
        case .claudeCode: "Claude Code is paired for this demo. I can help shape or implement a Home update from the workspace you approve."
        case .hermes: "Your Hermes gateway is paired for this demo. Its memory and tools remain yours; Convos only sends this lane’s approved context."
        case .openClaw: "Your OpenClaw gateway is paired for this demo. I’ll use only the device and operator scopes shown in Agent access."
        case .grokBot: "This Grok Bot is live in your private Convos lane. Ask it to work, then choose whether to save or share the result."
        case .connectMCP: "Connect MCP is coming soon. No server or personal context is connected in this build."
        }
    }

    var connectionAvailability: ExternalAgentConnectionAvailability {
        switch self {
        case .codex, .town, .tasklet, .grokBot: .live
        case .connectMCP: .comingSoon
        case .claudeCode, .hermes, .openClaw: .preview
        }
    }

    var hasStoredConnection: Bool {
        switch self {
        case .codex: CodexConnectionStore.configuration() != nil
        case .town: TownConnectionStore.configuration() != nil
        case .tasklet: TaskletConnectionStore.configuration() != nil
        case .grokBot: GrokBotConnectionStore.configuration() != nil
        case .claudeCode, .hermes, .openClaw, .connectMCP: false
        }
    }
}

enum ExternalAgentConnectionAvailability: Equatable {
    case live
    case preview
    case comingSoon
}

/// Remembers providers the user has deliberately added independently of their
/// current credential state, so a disconnected agent stays in native pickers
/// and routes back through setup instead of silently disappearing.
enum AddedExternalAgentStore {
    private static let key: String = "external-agents.added-providers"

    static func providers(defaults: UserDefaults = .standard) -> [ExternalAgentProvider] {
        let remembered = Set(defaults.stringArray(forKey: key) ?? [])
        return ExternalAgentProvider.allCases.filter {
            $0.connectionAvailability == .live && remembered.contains($0.rawValue)
        }
    }

    static func remember(_ provider: ExternalAgentProvider, defaults: UserDefaults = .standard) {
        guard provider.connectionAvailability == .live else { return }
        var values = Set(defaults.stringArray(forKey: key) ?? [])
        values.insert(provider.rawValue)
        defaults.set(Array(values).sorted(), forKey: key)
    }
}

struct ExternalAgentConnectionRequirement: Identifiable {
    let symbol: String
    let title: String
    let detail: String

    var id: String { title }
}

struct ExternalAgentAccess: Equatable {
    var desktopReadWrite: Bool
    var groupListenAndReply: Bool
    var scopedMemberDMs: Bool

    static let privateDesktop: ExternalAgentAccess = .init(
        desktopReadWrite: true,
        groupListenAndReply: false,
        scopedMemberDMs: false
    )
}

struct ExternalAgentOnboardingView: View {
    let prototypeState: AgentChatPrototypeState
    let onConnected: (ExternalAgentProvider) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var selectedProvider: ExternalAgentProvider?

    init(
        prototypeState: AgentChatPrototypeState,
        initialProvider: ExternalAgentProvider? = nil,
        onConnected: @escaping (ExternalAgentProvider) -> Void
    ) {
        self.prototypeState = prototypeState
        self.onConnected = onConnected
        _selectedProvider = State(initialValue: initialProvider)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                    introduction
                    providerList
                    privacyNote
                }
                .padding(.horizontal, DesignConstants.Spacing.step5x)
                .padding(.top, DesignConstants.Spacing.step5x)
                .padding(.bottom, DesignConstants.Spacing.step12x)
            }
            .background(.colorBackgroundSurfaceless)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .navigationDestination(item: $selectedProvider) { provider in
                connectionView(provider)
            }
        }
        .environment(\.colorScheme, .light)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            agentConstellation
                .frame(maxWidth: .infinity)
                .padding(.bottom, DesignConstants.Spacing.step2x)
            Text("Bring any agent to Convos")
                .font(.largeTitle.bold())
                .tracking(-1.0)
                .foregroundStyle(.colorTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Keep the agent you already trust. Your personal lane stays private; you decide what context it gets and what, if anything, goes back to a group.")
                .font(.title3)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var agentConstellation: some View {
        ZStack {
            Circle()
                .fill(Color.colorFillPrimary)
                .frame(width: 78, height: 78)
                .overlay {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.colorTextPrimaryInverted)
                }

            ForEach(Array(ExternalAgentProvider.allCases.enumerated()), id: \.element.id) { index, provider in
                providerBadge(provider, size: 44)
                    .offset(constellationOffset(at: index))
            }
        }
        .frame(height: 152)
        .accessibilityHidden(true)
    }

    private var providerList: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            ForEach(ExternalAgentProvider.allCases) { provider in
                Button {
                    selectedProvider = provider
                } label: {
                    HStack(spacing: DesignConstants.Spacing.step3x) {
                        providerBadge(provider, size: 46)
                        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                            Text(provider.displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.colorTextPrimary)
                            Text(provider.shortDescription)
                                .font(.footnote)
                                .foregroundStyle(.colorTextSecondary)
                        }
                        Spacer(minLength: DesignConstants.Spacing.step2x)
                        if let status = providerStatus(provider) {
                            Text(status)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.colorTextSecondary)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.colorTextSecondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                    .frame(minHeight: 68)
                    .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows what is needed to connect \(provider.displayName)")
            }
        }
    }

    private var privacyNote: some View {
        Label {
            Text("Codex, Town, Tasklet, and Grok Bot keep their connection credentials in the iPhone Keychain. Connect MCP is clearly marked Coming soon.")
        } icon: {
            Image(systemName: "lock.fill")
        }
        .font(.footnote)
        .foregroundStyle(.colorTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func connectionView(_ provider: ExternalAgentProvider) -> some View {
        if provider == .codex {
            CodexConnectionSetupView {
                onConnected(.codex)
            }
        } else if provider == .town {
            TownConnectionSetupView {
                onConnected(.town)
            }
        } else if provider == .tasklet {
            TaskletConnectionSetupView {
                onConnected(.tasklet)
            }
        } else if provider == .grokBot {
            GrokBotConnectionSetupView {
                onConnected(.grokBot)
            }
        } else {
            demoConnectionView(provider)
        }
    }

    private func demoConnectionView(_ provider: ExternalAgentProvider) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                    providerBadge(provider, size: 68)
                    Text(provider.connectionTitle)
                        .font(.largeTitle.bold())
                        .tracking(-0.8)
                        .foregroundStyle(.colorTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(provider.connectionExplanation)
                        .font(.body)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: DesignConstants.Spacing.step5x) {
                    ForEach(provider.requirements) { requirement in
                        HStack(alignment: .top, spacing: DesignConstants.Spacing.step4x) {
                            Image(systemName: requirement.symbol)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(provider.tint)
                                .frame(width: 32, height: 32)
                                .background(provider.tint.opacity(0.1), in: .circle)
                            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                                Text(requirement.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.colorTextPrimary)
                                Text(requirement.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.colorTextSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                Label(
                    provider.connectionAvailability == .comingSoon
                        ? "Coming soon — this provider cannot be added yet"
                        : "Connection preview — no account or secret is used",
                    systemImage: provider.connectionAvailability == .comingSoon ? "clock.fill" : "sparkles"
                )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step5x)
            .padding(.top, DesignConstants.Spacing.step5x)
            .padding(.bottom, 120)
        }
        .background(.colorBackgroundSurfaceless)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Text(provider.connectionAvailability == .comingSoon ? "Coming soon" : "Preview only")
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorTextSecondary)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(.colorFillMinimal, in: .rect(cornerRadius: 16))
            .padding(.horizontal, DesignConstants.Spacing.step5x)
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .background(.colorBackgroundSurfaceless)
        }
    }

    private func providerBadge(_ provider: ExternalAgentProvider, size: CGFloat) -> some View {
        Image(systemName: provider.symbolName)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(provider.tint, in: .circle)
    }

    private func constellationOffset(at index: Int) -> CGSize {
        let offsets: [CGSize] = [
            .init(width: -104, height: -30),
            .init(width: -66, height: 56),
            .init(width: 6, height: -66),
            .init(width: 68, height: 54),
            .init(width: 108, height: -28),
            .init(width: 0, height: 72),
            .init(width: -110, height: 24),
            .init(width: 110, height: 24),
        ]
        return offsets[index]
    }

    private func providerStatus(_ provider: ExternalAgentProvider) -> String? {
        if provider == .grokBot,
           let configuration = GrokBotConnectionStore.configuration() {
            let count = configuration.enabledAgents.count
            return count == 0 ? "Connected" : "\(count) added"
        }
        if prototypeState.connectedExternalProviders.contains(provider) {
            return "Added"
        }
        switch provider.connectionAvailability {
        case .live:
            return nil
        case .preview:
            return "Preview"
        case .comingSoon:
            return "Coming soon"
        }
    }
}

struct ExternalAgentAccessSheet: View {
    let provider: ExternalAgentProvider
    @Binding var access: ExternalAgentAccess

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    accessToggle(
                        title: "Edit Home with me",
                        detail: "Read and write access to this convo’s desktop. Only you see this private lane.",
                        symbol: "rectangle.3.group.bubble.left.fill",
                        isOn: $access.desktopReadWrite
                    )
                    accessToggle(
                        title: "Join the group chat",
                        detail: "Listen and reply in the shared group when the agent has something useful to add.",
                        symbol: "person.3.fill",
                        isOn: $access.groupListenAndReply
                    )
                    accessToggle(
                        title: "Let members DM it",
                        detail: "Other members get a private lane with only the context scoped to this group.",
                        symbol: "bubble.left.and.bubble.right.fill",
                        isOn: $access.scopedMemberDMs
                    )
                } header: {
                    Text("Where \(provider.displayName) can show up")
                } footer: {
                    Text("Each permission is revocable. Private chats, other groups, and unapproved desktop content stay outside this agent’s context.")
                }

                Section {
                    Label("Demo connection", systemImage: "sparkles")
                    Label("Scoped to this convo", systemImage: "checkmark.shield.fill")
                } header: {
                    Text("Connection")
                }
            }
            .navigationTitle("Agent access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func accessToggle(
        title: String,
        detail: String,
        symbol: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            Label {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(provider.tint)
            }
        }
        .tint(.colorLava)
        .padding(.vertical, DesignConstants.Spacing.stepX)
    }
}
