import ConvosCore
import SwiftUI

/// Owns the connection detail view model via `@State`, so it is created
/// once per navigation push and survives re-evaluation of the presenting
/// builder. Entry points must push this wrapper: constructing
/// `AbilityDetailViewModel` inline in a navigation destination would hand
/// `AbilityDetailView` a fresh model on every parent invalidation,
/// silently dropping loaded usage (and the list's `.task`, keyed to view
/// identity, would not re-fire for the replacement). Same rationale as
/// `AbilitiesListScreen`.
struct AbilityDetailScreen: View {
    @State private var viewModel: AbilityDetailViewModel
    /// App-wide actions, injected only by the App Settings entry point. Nil
    /// from the in-convo browser, where disconnect stays out of reach (see
    /// `AbilitiesListView.navigableEntitledRow` and the composerModal push).
    private let onDisconnect: (() -> Void)?
    private let onReconnect: (() -> Void)?

    init(
        ability: AbilitiesAPI.Ability,
        usageSource: any ConnectionUsageSourcing,
        onDisconnect: (() -> Void)? = nil,
        onReconnect: (() -> Void)? = nil
    ) {
        _viewModel = State(initialValue: AbilityDetailViewModel(ability: ability, usageSource: usageSource))
        self.onDisconnect = onDisconnect
        self.onReconnect = onReconnect
    }

    var body: some View {
        AbilityDetailView(viewModel: viewModel, onDisconnect: onDisconnect, onReconnect: onReconnect)
    }
}

/// One connection's detail: identity header plus where the connection is in
/// use, in three sections -- the agents holding it, the people it has been
/// delegated to, and the conversations it is enabled in.
///
/// Entry points (both push it inside a `NavigationStack` the caller already
/// supplies, and both render the identical screen -- there is no per-surface
/// variant here, so no mode enum of its own):
/// - the app-wide Connections list (`ConnectionsBrowserMode.appSettings`),
///   from `AbilitiesListView.navigableEntitledRow`;
/// - the per-convo Connections browser
///   (`ConnectionsBrowserMode.composerModal`), from the Connected row's
///   disclosure, which is a separate tap target from the row's toggle.
///
/// People always leads with the owner's own row ("You") and holds nothing
/// else yet: delegation to other members arrives with the Entitlement Actor
/// Model, and its rows append below the owner when they do.
///
/// Rows carry an explicit `colorBackgroundRaised` surface over the screen's
/// `colorBackgroundRaisedSecondary`, the same pairing conversation member
/// rows use. Without it the rows inherit the system grouped-row material,
/// which reads as a card in light mode and as nothing at all in dark.
struct AbilityDetailView: View {
    @Bindable var viewModel: AbilityDetailViewModel
    /// App-wide disconnect/reconnect, injected only from App Settings. Nil
    /// hides the action section, keeping the in-convo browser read-only.
    var onDisconnect: (() -> Void)?
    var onReconnect: (() -> Void)?
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var showDisconnectConfirmation: Bool = false

    var body: some View {
        List {
            headerSection
            actionSection
            agentsSection
            peopleSection
            conversationsSection
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .navigationTitle(viewModel.ability.displayName.resolved())
        .navigationBarTitleDisplayMode(.inline)
        .overlay { loadingOverlay }
        .task { await viewModel.refresh() }
        .confirmationDialog(
            "Disconnect \(viewModel.ability.displayName.resolved())?",
            isPresented: $showDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                onDisconnect?()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityIdentifier("ability-detail-\(viewModel.ability.id)")
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                AbilityIconView(ability: viewModel.ability)
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(viewModel.ability.displayName.resolved())
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                    Text(viewModel.ability.subtitle.resolved())
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            // Name and subtitle read as one element rather than two texts.
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Color.colorBackgroundRaised)
        .listSectionMargins(.top, DesignConstants.Spacing.step3x)
        // Pull the action buttons up close under the card.
        .listSectionSpacing(DesignConstants.Spacing.step2x)
    }

    /// App-wide actions, directly under the identity card. Present only when
    /// the App Settings entry point injected `onDisconnect`; the in-convo
    /// browser leaves it off. Reconnect leads only when the connection is
    /// broken, where the removed list menu used to offer it.
    @ViewBuilder
    private var actionSection: some View {
        if onDisconnect != nil {
            Section {
                VStack(spacing: DesignConstants.Spacing.step3x) {
                    reconnectButton
                    disconnectButton
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            // Zero the row insets so the full-width buttons span the same
            // width as the cards, whose backgrounds fill the whole cell.
            .listRowInsets(EdgeInsets())
            .listSectionMargins(.top, 0)
        }
    }

    @ViewBuilder
    private var reconnectButton: some View {
        if needsReconnect, let onReconnect {
            let reconnectAction: () -> Void = {
                onReconnect()
                dismiss()
            }
            Button("Reconnect", action: reconnectAction)
                .convosButtonStyle(.rounded(fullWidth: true))
                .accessibilityIdentifier("ability-detail-reconnect")
        }
    }

    private var disconnectButton: some View {
        let disconnectAction: () -> Void = { showDisconnectConfirmation = true }
        return Button("Disconnect", action: disconnectAction)
            .buttonStyle(RoundedDestructiveButtonStyle(fullWidth: true))
            .accessibilityIdentifier("ability-detail-disconnect")
    }

    /// The states that repair in place. `revoked` is routed to Discover
    /// (see `AbilitiesListViewModel.section(for:)`), so it never reaches
    /// this screen and offers no Reconnect.
    private var needsReconnect: Bool {
        switch viewModel.ability.entitlement?.status {
        case .expired, .needsReauth:
            true
        default:
            false
        }
    }

    @ViewBuilder
    private var agentsSection: some View {
        Section {
            if viewModel.agents.isEmpty {
                emptyRow(agentsEmptyTitle, identifier: "connection-detail-agents-empty")
            } else {
                ForEach(viewModel.agents) { agent in
                    usageRow(agent.displayName, identifier: "connection-detail-agent-\(agent.inboxId)")
                }
            }
        } header: {
            sectionHeader("Agents")
        }
        .listRowBackground(Color.colorBackgroundRaised)
    }

    /// Never empty: the owner's own row always leads it. Delegated people
    /// append below once anything writes them.
    private var peopleSection: some View {
        Section {
            ForEach(viewModel.people) { person in
                usageRow(person.displayName, identifier: "connection-detail-person-\(person.inboxId)")
            }
        } header: {
            sectionHeader("People")
        }
        .listRowBackground(Color.colorBackgroundRaised)
    }

    @ViewBuilder
    private var conversationsSection: some View {
        Section {
            if viewModel.conversations.isEmpty {
                emptyRow(conversationsEmptyTitle, identifier: "connection-detail-convos-empty")
            } else {
                ForEach(viewModel.conversations) { conversation in
                    usageRow(
                        conversation.displayName,
                        identifier: "connection-detail-convo-\(conversation.conversationId)"
                    )
                }
            }
        } header: {
            sectionHeader("Convos")
        }
        .listRowBackground(Color.colorBackgroundRaised)
    }

    // MARK: - Copy

    /// A read that reached no conversation cannot claim the connection is
    /// unused: it says what it knows, which is nothing.
    private var agentsEmptyTitle: String {
        viewModel.isUnavailable ? Constant.unavailableTitle : "None"
    }

    private var conversationsEmptyTitle: String {
        viewModel.isUnavailable ? Constant.unavailableTitle : "None"
    }

    // MARK: - Rows

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.colorTextSecondary)
    }

    private func usageRow(_ title: String, identifier: String) -> some View {
        Text(title)
            .font(.body)
            .foregroundStyle(.colorTextPrimary)
            .accessibilityIdentifier(identifier)
    }

    private func emptyRow(_ title: String, identifier: String) -> some View {
        Text(title)
            .font(.body)
            .foregroundStyle(.colorTextSecondary)
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if viewModel.isLoading, !viewModel.hasLoadedOnce {
            ProgressView()
        }
    }

    private enum Constant {
        static let unavailableTitle: String = "Can't check this right now"
    }
}

// MARK: - Previews

#Preview("Populated") {
    let gcal = MockAbilitiesService.standardCatalog().first { $0.id == "googlecalendar" }
    if let gcal {
        NavigationStack {
            AbilityDetailScreen(
                ability: gcal,
                usageSource: PreviewConnectionUsageSource(),
                onDisconnect: {},
                onReconnect: {}
            )
        }
    }
}

#Preview("Empty") {
    let youtube = MockAbilitiesService.standardCatalog().first { $0.id == "youtube" }
    if let youtube {
        NavigationStack {
            AbilityDetailScreen(ability: youtube, usageSource: PreviewConnectionUsageSource())
        }
    }
}
