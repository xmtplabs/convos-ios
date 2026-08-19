import ConvosComposer
import SwiftUI

enum ExternalAgentProvider: String, CaseIterable, Hashable, Identifiable {
    case codex
    case claudeCode
    case hermes
    case openClaw
    case grokBot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .hermes: "Hermes"
        case .openClaw: "OpenClaw"
        case .grokBot: "Grok Bot"
        }
    }

    var shortDescription: String {
        switch self {
        case .codex: "OpenAI coding agent"
        case .claudeCode: "Anthropic coding agent"
        case .hermes: "Your self-hosted Hermes agent"
        case .openClaw: "Your OpenClaw gateway"
        case .grokBot: "Grok Bot app connection demo"
        }
    }

    var chatSubtitle: String {
        switch self {
        case .codex: "Connected demo · Private desktop collaborator"
        case .claudeCode: "Connected demo · Private desktop collaborator"
        case .hermes: "Paired gateway demo · Scoped to this convo"
        case .openClaw: "Paired gateway demo · Scoped to this convo"
        case .grokBot: "Connection demo · Scoped to this convo"
        }
    }

    var symbolName: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claudeCode: "terminal.fill"
        case .hermes: "h.circle.fill"
        case .openClaw: "antenna.radiowaves.left.and.right"
        case .grokBot: "desktopcomputer"
        }
    }

    var tint: Color {
        switch self {
        case .codex: Color(red: 0.08, green: 0.08, blue: 0.09)
        case .claudeCode: Color(red: 0.72, green: 0.36, blue: 0.20)
        case .hermes: Color(red: 0.23, green: 0.38, blue: 0.74)
        case .openClaw: Color(red: 0.77, green: 0.17, blue: 0.13)
        case .grokBot: Color(red: 0.12, green: 0.12, blue: 0.14)
        }
    }

    var connectionTitle: String {
        switch self {
        case .codex: "Pair Codex from your desktop"
        case .claudeCode: "Pair Claude Code from your desktop"
        case .hermes: "Connect your Hermes gateway"
        case .openClaw: "Connect your OpenClaw gateway"
        case .grokBot: "Connect the Grok Bot app"
        }
    }

    var connectionExplanation: String {
        switch self {
        case .codex:
            "Convos would pair with a small desktop bridge, then use your existing Codex sign-in or an OpenAI project key kept off the phone."
        case .claudeCode:
            "Convos would pair with Claude Code on your computer after you authenticate with Anthropic, Claude Pro or Max, Bedrock, or Vertex AI."
        case .hermes:
            "Hermes exposes an OpenAI-compatible API server. Convos would pair to that gateway with its URL and API server key."
        case .openClaw:
            "Convos would become an approved OpenClaw device, connecting to its WebSocket gateway with a token and explicit operator scopes."
        case .grokBot:
            "Grok Bot is a separate macOS and iOS app. This local prototype shows what a future scoped connection could feel like, but it does not exchange live data."
        }
    }

    var requirements: [ExternalAgentConnectionRequirement] {
        switch self {
        case .codex:
            [
                .init(symbol: "desktopcomputer", title: "Convos desktop bridge", detail: "Pairs this convo to the machine where Codex can work."),
                .init(symbol: "person.crop.circle.badge.checkmark", title: "OpenAI authorization", detail: "Sign in with ChatGPT or use a server-held project API key."),
                .init(symbol: "folder.badge.gearshape", title: "Approved workspace", detail: "Choose which project and tools this convo may reach."),
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
                .init(symbol: "macbook.and.iphone", title: "Grok Bot app", detail: "The separate Grok Bot app installed on your iPhone or Mac."),
                .init(symbol: "point.3.connected.trianglepath.dotted", title: "Supported connector", detail: "A provider-supported connection is required before Convos can exchange data."),
                .init(symbol: "checkmark.shield.fill", title: "Convo scope", detail: "Only the messages and Home objects you approve are sent."),
            ]
        }
    }

    var welcomeMessage: String {
        switch self {
        case .codex: "Codex is paired for this demo. Point me at a Home card or describe what you want to build, and I’ll keep the work inside the access you chose."
        case .claudeCode: "Claude Code is paired for this demo. I can help shape or implement a Home update from the workspace you approve."
        case .hermes: "Your Hermes gateway is paired for this demo. Its memory and tools remain yours; Convos only sends this lane’s approved context."
        case .openClaw: "Your OpenClaw gateway is paired for this demo. I’ll use only the device and operator scopes shown in Agent access."
        case .grokBot: "Grok Bot is shown as a local connection demo. No live data leaves Convos in this build."
        }
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
    @State private var connectingProvider: ExternalAgentProvider?

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
                .font(.system(size: 38, weight: .bold))
                .tracking(-1.0)
                .foregroundStyle(.colorTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Keep the agent you already trust. Give it one private lane, one clear context boundary, and exactly the places it may show up.")
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
                        if prototypeState.connectedExternalProviders.contains(provider) {
                            Text("Added")
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
            Text("Credentials stay in the connector or paired desktop. Convos receives a revocable connection—not your raw secret.")
        } icon: {
            Image(systemName: "lock.fill")
        }
        .font(.footnote)
        .foregroundStyle(.colorTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func connectionView(_ provider: ExternalAgentProvider) -> some View {
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

                Label("Clickable prototype — no account or secret is used", systemImage: "sparkles")
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
            Button {
                connectDemo(provider)
            } label: {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    if connectingProvider == provider {
                        ProgressView()
                            .tint(.colorTextPrimaryInverted)
                    }
                    Text(connectButtonTitle(provider))
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.colorTextPrimaryInverted)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(.colorFillPrimary, in: .rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .disabled(connectingProvider != nil)
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
            .init(width: -104, height: -28),
            .init(width: -58, height: 58),
            .init(width: 62, height: 56),
            .init(width: 108, height: -26),
            .init(width: 4, height: -64),
        ]
        return offsets[index]
    }

    private func connectButtonTitle(_ provider: ExternalAgentProvider) -> String {
        if connectingProvider == provider { return "Pairing demo…" }
        if prototypeState.connectedExternalProviders.contains(provider) { return "Open \(provider.displayName)" }
        return "Connect demo"
    }

    private func connectDemo(_ provider: ExternalAgentProvider) {
        connectingProvider = provider
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            connectingProvider = nil
            onConnected(provider)
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
