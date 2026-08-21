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
        titledContent
            .background(.colorBackgroundRaisedSecondary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: ExternalAgentProvider.self) { provider in
                destination(for: provider)
            }
            .onAppear { reloadConnections() }
    }

    /// The tab root leaves the navigation title empty on purpose: the shell's
    /// `AppIndicatorPill` owns that zone on every tab root, exactly as it does
    /// on Convos and Contacts. Inside the settings sheet an inline title is
    /// what every sibling sub-page carries.
    @ViewBuilder
    private var titledContent: some View {
        if mode.showsNavigationTitle {
            scroller.navigationTitle("Agents")
        } else {
            scroller
        }
    }

    private var scroller: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                previewBackendNotice
                introduction
                connectedSection
                discoverSection
                privacyNote
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.top, topPadding)
            .padding(.bottom, DesignConstants.Spacing.step12x)
        }
    }

    /// The tab root scrolls under the app-indicator pill, which hangs slightly
    /// below the navigation bar it shares the zone with.
    private var topPadding: CGFloat {
        switch mode {
        case .tabRoot: DesignConstants.Spacing.step3x
        case .settingsPage: DesignConstants.Spacing.step2x
        }
    }

    private var connected: [ExternalAgentProvider] {
        ExternalAgentProvider.allCases.filter { connectedProviders.contains($0) }
    }

    private var available: [ExternalAgentProvider] {
        ExternalAgentProvider.allCases.filter { !connectedProviders.contains($0) }
    }

    @ViewBuilder
    private var previewBackendNotice: some View {
        if ConfigManager.shared.isAgentRelayPreviewBuild {
            AgentComposerNotice(message: AgentSetupCopy.previewBackendNote, onDismiss: {})
                .accessibilityIdentifier("agents-preview-backend-notice")
        }
    }

    /// Shown only while nothing is connected. Once an agent is on the list the
    /// list is the content, the way the Contacts tab drops its invite-first
    /// framing once you have contacts.
    @ViewBuilder
    private var introduction: some View {
        if connected.isEmpty {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                Text("Bring your own agent")
                    .font(.convosTitle)
                    .tracking(Font.convosTitleTracking)
                    .foregroundStyle(.colorTextPrimary)
                Text(AgentSetupCopy.homeIntroduction)
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
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
        connectedProviders = Set(ExternalAgentProvider.allCases.filter { provider in
            (try? dependencies.connectionStore.load(provider: provider)) != nil
        })
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

#Preview("Provider rows") {
    VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
        Text("Your agents")
            .font(.caption)
            .foregroundStyle(.colorTextSecondary)
            .padding(.leading, DesignConstants.Spacing.step2x)
        AgentProviderRow(provider: .tasklet, isConnected: true)
        Text("Discover")
            .font(.caption)
            .foregroundStyle(.colorTextSecondary)
            .padding(.leading, DesignConstants.Spacing.step2x)
        AgentProviderRow(provider: .town, isConnected: false)
    }
    .padding(DesignConstants.Spacing.step4x)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(.colorBackgroundRaisedSecondary)
}
