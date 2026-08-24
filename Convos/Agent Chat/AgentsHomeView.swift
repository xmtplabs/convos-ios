import ConvosCore
import SwiftUI

/// The Agents destination. One screen, two entry points:
///
/// - the Agents tab (`MainTabView`, `AgentsHomeMode.tabRoot`)
/// - the App Settings "Agents" row (`AppSettingsView`, `.settingsPage`)
///
/// Both push the same provider destinations onto whichever navigation stack
/// they are hosted in, so there is one implementation of "what an agent
/// connection is" and one place a provider's chat or setup screen is reached.
struct AgentsHomeView: View {
    let mode: AgentsHomeMode
    let dependencies: AgentRelayDependencies
    let session: any SessionManagerProtocol
    @State private var connectedProviders: Set<ExternalAgentProvider> = []

    var body: some View {
        AgentsHomeContent(connectedProviders: connectedProviders, topPadding: mode.topPadding)
            .background(.colorBackgroundRaisedSecondary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: ExternalAgentProvider.self) { provider in
                destination(for: provider)
            }
            .onAppear { reloadConnections() }
    }

    @ViewBuilder
    private func destination(for provider: ExternalAgentProvider) -> some View {
        if connectedProviders.contains(provider) {
            AgentChatView(provider: provider, dependencies: dependencies, session: session)
        } else {
            setup(for: provider)
        }
    }

    @ViewBuilder
    private func setup(for provider: ExternalAgentProvider) -> some View {
        switch provider {
        case .town:
            TownSetupView(dependencies: dependencies, session: session)
        case .tasklet:
            TaskletSetupView(dependencies: dependencies, session: session)
        }
    }

    private func reloadConnections() {
        var loadedProviders: Set<ExternalAgentProvider> = []
        do {
            for provider in ExternalAgentProvider.allCases
                where try dependencies.connectionStore.load(provider: provider) != nil {
                loadedProviders.insert(provider)
            }
        } catch {
            Log.error("Failed to reload agent connections: \(error.localizedDescription)")
            return
        }
        connectedProviders = loadedProviders
    }
}

/// The Agents screen's content, split from the screen so every state it can
/// be in - nothing connected, one agent connected, a build that cannot reach
/// a relay - is reachable in a preview without a database, a Keychain entry
/// or a live backend behind it.
struct AgentsHomeContent: View {
    let connectedProviders: Set<ExternalAgentProvider>
    let topPadding: CGFloat

    private var connected: [ExternalAgentProvider] {
        ExternalAgentProvider.allCases.filter { connectedProviders.contains($0) }
    }

    private var available: [ExternalAgentProvider] {
        ExternalAgentProvider.allCases.filter { !connectedProviders.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                header
                previewBackendNotice
                connectedSection
                discoverSection
                privacyNote
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.top, topPadding)
            .padding(.bottom, DesignConstants.Spacing.step12x)
        }
    }

    /// The screen's own title, carried by the content rather than the
    /// navigation bar - the pattern Connections and Abilities already use, and
    /// what makes this read as a destination rather than a settings row that
    /// opened. The sentence under it is the whole idea of the feature, so it
    /// teaches while the list is empty and stays true once it is not.
    private var header: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            Text("Connect")
                .font(.convosTitle)
                .tracking(Font.convosTitleTracking)
                .foregroundStyle(.colorTextPrimary)
            Text(AgentSetupCopy.homeIntroduction)
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DesignConstants.Spacing.step2x)
    }

    @ViewBuilder
    private var previewBackendNotice: some View {
        if ConfigManager.shared.isAgentRelayPreviewBackend {
            AgentComposerNotice(message: AgentSetupCopy.previewBackendNote, onDismiss: {})
                .accessibilityIdentifier("agents-preview-backend-notice")
        }
    }

    @ViewBuilder
    private var connectedSection: some View {
        if !connected.isEmpty {
            section(title: "Your agents", providers: connected)
        }
    }

    @ViewBuilder
    private var discoverSection: some View {
        if !available.isEmpty {
            section(title: "Discover", providers: available)
        }
    }

    private func section(title: String, providers: [ExternalAgentProvider]) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .padding(.leading, DesignConstants.Spacing.step2x)
            ForEach(providers) { provider in
                NavigationLink(value: provider) {
                    AgentProviderRow(provider: provider, isConnected: connectedProviders.contains(provider))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var privacyNote: some View {
        Text(AgentSetupCopy.transcriptStaysHere)
            .font(.caption)
            .foregroundStyle(.colorTextTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DesignConstants.Spacing.step2x)
    }
}

/// One provider. Structurally the same row as `ContactsPickerActionRow` - a
/// 56pt tile, a title, a subtitle - so the Agents list lines up with the rows
/// the rest of the app uses. The tile is filled when the agent is connected
/// and neutral when it is not, which is the state the row is really reporting.
struct AgentProviderRow: View {
    let provider: ExternalAgentProvider
    let isConnected: Bool

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            iconTile
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(provider.displayName)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0.0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.colorTextTertiary)
        }
        .padding(.vertical, DesignConstants.Spacing.stepX)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-provider-row-\(provider.rawValue)")
    }

    private var subtitle: String {
        isConnected ? "Connected" : AgentSetupCopy.discoverSubtitle(for: provider)
    }

    private var subtitleColor: Color {
        isConnected ? .colorGreen : .colorTextSecondary
    }

    private var iconTile: some View {
        let fill: Color = isConnected ? .colorTextPrimary : .colorFillMinimal
        let glyph: Color = isConnected ? .colorTextPrimaryInverted : .colorTextSecondary
        return Image(systemName: provider.symbolName)
            .font(.title3)
            .foregroundStyle(glyph)
            .frame(width: Constant.tileSize, height: Constant.tileSize)
            .background(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarger).fill(fill))
    }

    private enum Constant {
        static let tileSize: CGFloat = 56.0
    }
}

// MARK: - Previews

#Preview("Nothing connected") {
    NavigationStack {
        AgentsHomeContent(connectedProviders: [], topPadding: DesignConstants.Spacing.step3x)
            .background(.colorBackgroundRaisedSecondary)
    }
}

#Preview("Nothing connected, dark") {
    NavigationStack {
        AgentsHomeContent(connectedProviders: [], topPadding: DesignConstants.Spacing.step3x)
            .background(.colorBackgroundRaisedSecondary)
    }
    .preferredColorScheme(.dark)
}

#Preview("One agent connected") {
    NavigationStack {
        AgentsHomeContent(connectedProviders: [.tasklet], topPadding: DesignConstants.Spacing.step3x)
            .background(.colorBackgroundRaisedSecondary)
    }
}

#Preview("One agent connected, dark") {
    NavigationStack {
        AgentsHomeContent(connectedProviders: [.tasklet], topPadding: DesignConstants.Spacing.step3x)
            .background(.colorBackgroundRaisedSecondary)
    }
    .preferredColorScheme(.dark)
}

#Preview("Provider rows") {
    VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
        AgentProviderRow(provider: .tasklet, isConnected: true)
        AgentProviderRow(provider: .town, isConnected: false)
    }
    .padding(DesignConstants.Spacing.step4x)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(.colorBackgroundRaisedSecondary)
}
