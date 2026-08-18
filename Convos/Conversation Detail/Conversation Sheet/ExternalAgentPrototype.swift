import ConvosComposer
import SwiftUI
import UIKit

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
        case .codex: "Open Codex with scoped Convos context"
        case .claudeCode: "Take group context to Claude Code"
        case .hermes: "Copy context to your Hermes agent"
        case .openClaw: "Open your OpenClaw gateway with context"
        case .grokBot: "Open the Grok Bot app with scoped Convos context"
        }
    }

    var chatSubtitle: String {
        "Context handoff · Opens \(displayName)"
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
        "Add \(displayName) as a context handoff"
    }

    var connectionExplanation: String {
        "Convos will not create another chat. Choose how much group context to copy, open \(displayName), and paste it into the agent you already use."
    }

    var launchURL: URL {
        let destination: String = switch self {
        case .codex: "https://chatgpt.com/codex"
        case .claudeCode: "https://claude.ai/new"
        case .hermes: "https://github.com/NousResearch/hermes-agent"
        case .openClaw: "https://github.com/openclaw/openclaw"
        case .grokBot: "sand://app/v1/open"
        }
        guard let url = URL(string: destination) else {
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    var connectorKey: String {
        "CONVOS-DEMO-\(rawValue.uppercased())-7K4D-2Q9M"
    }

    var maskedConnectorKey: String {
        "CVS•\(rawValue.prefix(4).uppercased())••••••2Q9M"
    }

    func contextPayload(configuration: ExternalAgentHandoffConfiguration) -> String {
        let desktopLine: String = configuration.includesGroupDesktop
            ? "Included: group messages in this window + group desktop information"
            : "Included: group messages in this window"
        return """
        CONVOS CONTEXT HANDOFF — CLICKABLE PROTOTYPE

        Open with: \(displayName)
        Context window: \(configuration.contextWindow.payloadTitle)
        \(desktopLine)
        Excluded: Ghost Mode, private agent chats, member DMs, other convos, and unsaved files

        GROUP SNAPSHOT
        • The group is coordinating an upcoming trip and the shared desktop.
        • Recent decisions, links, and open questions would appear here.
        • Desktop cards would be summarized as titles, links, and current state—not hidden data.

        USER REQUEST
        Use this context as background. Ask before treating any inferred detail as a confirmed group decision.

        Prototype note: this Firebase build does not export real conversation content yet.
        """
    }
}

enum ExternalAgentContextWindow: String, CaseIterable, Equatable, Identifiable {
    case oneHour
    case twentyFourHours
    case sevenDays
    case allAvailable

    var id: String { rawValue }

    var pickerTitle: String {
        switch self {
        case .oneHour: "1 hr"
        case .twentyFourHours: "24 hr"
        case .sevenDays: "7 days"
        case .allAvailable: "All"
        }
    }

    var summaryTitle: String {
        switch self {
        case .oneHour: "last hour"
        case .twentyFourHours: "last 24 hours"
        case .sevenDays: "last 7 days"
        case .allAvailable: "all available history"
        }
    }

    var payloadTitle: String {
        switch self {
        case .oneHour: "Last hour"
        case .twentyFourHours: "Last 24 hours"
        case .sevenDays: "Last 7 days"
        case .allAvailable: "All available history"
        }
    }
}

struct ExternalAgentHandoffConfiguration: Equatable {
    var contextWindow: ExternalAgentContextWindow
    var includesGroupDesktop: Bool

    static let standard: ExternalAgentHandoffConfiguration = .init(
        contextWindow: .twentyFourHours,
        includesGroupDesktop: true
    )

    var summary: String {
        let desktopSuffix: String = includesGroupDesktop ? " + group desktop info" : ""
        return "Share \(contextWindow.summaryTitle)\(desktopSuffix)"
    }
}

struct ExternalAgentConnectionStep: Identifiable {
    let symbol: String
    let title: String
    let detail: String

    var id: String { title }
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
            handoffGraphic
                .frame(maxWidth: .infinity)
                .padding(.bottom, DesignConstants.Spacing.step2x)
            Text("Take Convos context anywhere")
                .font(.system(size: 38, weight: .bold))
                .tracking(-1.0)
                .foregroundStyle(.colorTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Keep chatting in the agent you already use. Convos packages only the group context you choose, then opens the destination for you.")
                .font(.title3)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var handoffGraphic: some View {
        HStack(spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: "person.3.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .frame(width: 60, height: 60)
                .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
            Image(systemName: "doc.on.clipboard.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.colorTextPrimaryInverted)
                .frame(width: 64, height: 64)
                .background(.colorLava, in: .circle)
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .frame(width: 60, height: 60)
                .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
        }
        .frame(height: 132)
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
                .accessibilityHint("Explains the context handoff to \(provider.displayName)")
            }
        }
    }

    private var privacyNote: some View {
        Label {
            Text("Nothing is sent automatically. Context leaves Convos only after you copy it and paste it into another agent.")
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
                    ForEach(connectionSteps(for: provider)) { step in
                        HStack(alignment: .top, spacing: DesignConstants.Spacing.step4x) {
                            Image(systemName: step.symbol)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(provider.tint)
                                .frame(width: 32, height: 32)
                                .background(provider.tint.opacity(0.1), in: .circle)
                            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                                Text(step.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.colorTextPrimary)
                                Text(step.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.colorTextSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                Label("Clickable prototype — copied context and connector keys are demo-only", systemImage: "sparkles")
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

    private func connectionSteps(for provider: ExternalAgentProvider) -> [ExternalAgentConnectionStep] {
        [
            .init(
                symbol: "clock.fill",
                title: "Choose the time window",
                detail: "Start with the last 24 hours, then include more or less group history when you need it."
            ),
            .init(
                symbol: "doc.on.clipboard.fill",
                title: "Copy only that context",
                detail: "Optionally include the group desktop. Ghost Mode, private DMs, and other convos stay out."
            ),
            .init(
                symbol: "arrow.up.forward.app.fill",
                title: "Open \(provider.displayName) and paste",
                detail: "The conversation continues in \(provider.displayName), not in a duplicate chat inside Convos."
            ),
        ]
    }

    private func providerBadge(_ provider: ExternalAgentProvider, size: CGFloat) -> some View {
        Image(systemName: provider.symbolName)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(provider.tint, in: .circle)
    }

    private func connectButtonTitle(_ provider: ExternalAgentProvider) -> String {
        if connectingProvider == provider { return "Adding…" }
        if prototypeState.connectedExternalProviders.contains(provider) { return "Open handoff" }
        return "Add \(provider.displayName)"
    }

    private func connectDemo(_ provider: ExternalAgentProvider) {
        connectingProvider = provider
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            connectingProvider = nil
            onConnected(provider)
        }
    }
}

struct ExternalAgentContextHandoffView: View {
    let provider: ExternalAgentProvider
    let prototypeState: AgentChatPrototypeState
    let extraBottomInset: CGFloat
    var onContentHeightChanged: ((CGFloat) -> Void)?

    @State private var confirmation: String?

    private var configuration: ExternalAgentHandoffConfiguration {
        prototypeState.handoff(for: provider)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                heading
                contextControls
                copyContext
                returnAccess
                privacyBoundary
                Label("Clickable prototype — real group content and write access are not connected", systemImage: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step5x)
            .padding(.top, DesignConstants.Spacing.step6x)
            .padding(.bottom, extraBottomInset + DesignConstants.Spacing.step8x)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                onContentHeightChanged?(height)
            }
        }
        .background(.colorBackgroundSurfaceless)
        .overlay(alignment: .top) {
            if let confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                    .frame(minHeight: 44)
                    .background(.colorFillPrimary, in: .capsule)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                    .padding(.top, DesignConstants.Spacing.step3x)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: confirmation)
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step4x) {
            providerBadge(size: 64)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Text("Take this convo to \(provider.displayName)")
                    .font(.title2.bold())
                    .foregroundStyle(.colorTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This is a context handoff—not another chat.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var contextControls: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Choose context")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)

            Picker("Time range", selection: contextWindowBinding) {
                ForEach(ExternalAgentContextWindow.allCases) { window in
                    Text(window.pickerTitle).tag(window)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Controls how much group history will be copied")

            Toggle(isOn: includesDesktopBinding) {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text("Include group desktop info")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Text("Adds current links, cards, and widget summaries.")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                }
            }
            .tint(.colorLava)
            .padding(.vertical, DesignConstants.Spacing.step2x)

            Label(configuration.summary, systemImage: "checkmark.shield.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .padding(DesignConstants.Spacing.step4x)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
                .accessibilityLabel("Selected context: \(configuration.summary)")
        }
    }

    private var copyContext: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Text("Copy it")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            Text("Convos creates one paste-ready context block. Review the scope above, copy it, then open \(provider.displayName) from the bottom of the screen.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                UIPasteboard.general.string = provider.contextPayload(configuration: configuration)
                showConfirmation("Context copied")
            } label: {
                Label("Copy context", systemImage: "doc.on.doc.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(.colorFillPrimary, in: .rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Copies a demo context block for \(provider.displayName)")
        }
    }

    private var returnAccess: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Let \(provider.displayName) send updates back")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            Text("Paste a one-time Convos key into \(provider.displayName)’s secure connector. It can propose new links and widget updates for this group desktop.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignConstants.Spacing.step3x) {
                Image(systemName: "key.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorLava)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text(provider.maskedConnectorKey)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Text("Demo key · cannot write to Convos")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                }
                Spacer(minLength: 0)
                Button("Copy key") {
                    UIPasteboard.general.string = provider.connectorKey
                    showConfirmation("Demo key copied")
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .frame(minWidth: 88, minHeight: 44)
                .background(.colorFillSubtle, in: .rect(cornerRadius: 12))
                .accessibilityHint("Copies a non-functional prototype connector key")
            }
            .padding(DesignConstants.Spacing.step4x)
            .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Label("Create link and widget update proposals", systemImage: "checkmark.circle.fill")
                Label("No group messages, Ghost content, or private DMs", systemImage: "lock.fill")
                Label("Production design: one use, 10-minute expiry, revocable", systemImage: "clock.badge.checkmark")
            }
            .font(.footnote)
            .foregroundStyle(.colorTextSecondary)
        }
    }

    private var privacyBoundary: some View {
        Label {
            Text("Copied context includes only the selected group window. Ghost Mode, private chats, member DMs, other convos, and unsaved files always stay out.")
        } icon: {
            Image(systemName: "lock.fill")
        }
        .font(.footnote)
        .foregroundStyle(.colorTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var contextWindowBinding: Binding<ExternalAgentContextWindow> {
        Binding(
            get: { configuration.contextWindow },
            set: { window in
                var updated: ExternalAgentHandoffConfiguration = configuration
                updated.contextWindow = window
                prototypeState.setHandoff(updated, for: provider)
            }
        )
    }

    private var includesDesktopBinding: Binding<Bool> {
        Binding(
            get: { configuration.includesGroupDesktop },
            set: { includesDesktop in
                var updated: ExternalAgentHandoffConfiguration = configuration
                updated.includesGroupDesktop = includesDesktop
                prototypeState.setHandoff(updated, for: provider)
            }
        )
    }

    private func providerBadge(size: CGFloat) -> some View {
        Image(systemName: provider.symbolName)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(provider.tint, in: .circle)
    }

    private func showConfirmation(_ text: String) {
        confirmation = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if confirmation == text { confirmation = nil }
        }
    }
}

struct ExternalAgentLaunchBar: View {
    let provider: ExternalAgentProvider

    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        Button {
            openURL(provider.launchURL)
        } label: {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Text("Open \(provider.displayName)")
                    .font(.body.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.colorTextPrimary)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .frame(minHeight: 52)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .accessibilityHint("Leaves Convos and opens \(provider.displayName) or its website")
    }
}
