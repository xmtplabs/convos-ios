import ConvosComposer
import ConvosCore
import SwiftUI

/// Owns the abilities list view model via `@State`, so it is created once
/// per navigation push or sheet presentation and survives re-evaluation
/// of the presenting builder. Entry points must present this wrapper:
/// constructing `AbilitiesListViewModel` inline in a navigation
/// destination or sheet-content builder would hand `AbilitiesListView` a
/// fresh model on every parent invalidation, silently dropping loaded
/// catalog, busy, and pending-authorization state (and the list's
/// `.task`, keyed to view identity, would not re-fire for the
/// replacement).
struct AbilitiesListScreen: View {
    @State private var viewModel: AbilitiesListViewModel
    /// The per-chat half of `.composerModal`: opt-in state and the toggle
    /// writer for the launching DM. Nil in `.appSettings`, which has no
    /// conversation to scope to and must fire no conversation-abilities
    /// request at all.
    @State private var conversationViewModel: ConversationAbilitiesViewModel?
    /// Kept so entitled rows can hand the whole latched pair down to the
    /// ability detail push (see `AbilitiesSelection`).
    private let selection: AbilitiesSelection
    /// Which entry point raised the screen; drives the wrapper chrome, the
    /// section headers and the Connected row's accessory (see
    /// `ConnectionsBrowserMode`). Membership predicates are the same in
    /// both modes.
    private let mode: ConnectionsBrowserMode
    @Environment(\.dismiss) private var dismiss: DismissAction

    /// Takes the whole selection so the service and its authorizer are
    /// latched together for the screen's lifetime -- the halves must never
    /// be resolved at different times (see `AbilitiesSelection`).
    init(selection: AbilitiesSelection, mode: ConnectionsBrowserMode) {
        self.selection = selection
        self.mode = mode
        let listViewModel = AbilitiesListViewModel(service: selection.service, authorizer: selection.authorizer)
        let conversationViewModel = Self.makeConversationViewModel(listViewModel, selection: selection, mode: mode)
        if let conversationViewModel {
            Self.wireActivation(list: listViewModel, conversation: conversationViewModel)
        }
        _viewModel = State(initialValue: listViewModel)
        _conversationViewModel = State(initialValue: conversationViewModel)
    }

    /// Points the list view model's catalog and activation callbacks at
    /// the per-chat view model.
    ///
    /// The captures are **strong on purpose**. `@State` releases the
    /// per-chat view model the moment the modal is dismissed, but a
    /// connect already in flight still has to write its grant: dismissing
    /// before `beginEntitlement` returns would otherwise connect the
    /// ability app-wide and silently write no per-chat opt-in. The list
    /// view model outlives the dismissal through its own mutation task,
    /// so it carries the pipeline. No cycle results: the recovery route
    /// in the other direction captures the list view model weakly.
    static func wireActivation(
        list: AbilitiesListViewModel,
        conversation: ConversationAbilitiesViewModel
    ) {
        list.onCatalogCommitted = { catalog in
            conversation.adoptCatalog(catalog)
        }
        list.onEntitlementActivated = { abilityId in
            conversation.enableAfterConnect(abilityId: abilityId)
        }
    }

    /// Builds the per-chat view model for `.composerModal` and cross-wires
    /// it with the list view model: the list publishes every catalog
    /// revision it commits (so the lifecycle behind a toggle always comes
    /// from the snapshot that sectioned the row) and every entitlement it
    /// activates (so a connect from Discover enables the ability here).
    ///
    /// The two edges capture with deliberately different strengths. The
    /// forward edge (`wireActivation`) holds the per-chat view model
    /// **strongly**, so a connect already in flight still writes its grant
    /// after the modal is dismissed. The reverse edge wired here - the
    /// recovery route back into the list view model - captures **weakly**,
    /// which is what stops the pair from retaining each other.
    private static func makeConversationViewModel(
        _ listViewModel: AbilitiesListViewModel,
        selection: AbilitiesSelection,
        mode: ConnectionsBrowserMode
    ) -> ConversationAbilitiesViewModel? {
        guard let conversationId = mode.conversationId,
              let agentInboxId = mode.agentInboxId else {
            return nil
        }
        let agent = ConversationAgentDescriptor(
            inboxId: agentInboxId,
            displayName: mode.agentDisplayName ?? ""
        )
        let conversationViewModel = ConversationAbilitiesViewModel(
            conversationId: conversationId,
            agents: [agent],
            selection: selection,
            catalogSource: .hosted
        )
        conversationViewModel.entitlementRecoveryRoute = .host { [weak listViewModel] ability in
            listViewModel?.connect(ability)
        }
        return conversationViewModel
    }

    var body: some View {
        if mode.showsDismissChrome {
            NavigationStack {
                listView
                    .toolbar { doneToolbarItem }
            }
        } else {
            listView
        }
    }

    /// The sheets modifier rides the list, never the section: attached
    /// lower down it resolves the wrong presentation context and the
    /// bundle picker dismisses this modal instead of presenting.
    private var listView: some View {
        AbilitiesListView(
            viewModel: viewModel,
            selection: selection,
            mode: mode,
            conversationViewModel: conversationViewModel
        )
        .modifier(ConversationAbilitiesSheetsModifier(viewModel: conversationViewModel))
    }

    private var doneToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            let action = { dismiss() }
            Button("Done", action: action)
                .accessibilityIdentifier("connections-browser-done-button")
        }
    }
}

/// The V2 abilities catalog list: searchable, split into three sections by
/// entitlement state, with status badges and connect actions through
/// `AbilitiesServiceProtocol`.
///
/// Entry points (all flag-gated behind Abilities V2, all via
/// `AbilitiesListScreen`, which owns the view models and takes the
/// `ConnectionsBrowserMode` naming the caller):
/// - App Settings connections row (`AppSettingsView.connectionsDestination`)
///   pushes it in place of the V1 `ConnectionsListView`, in mode
///   `.appSettings`; the row is titled "Abilities" under the flag. Account
///   level throughout: "Connected" / "All connections" / "Status unknown",
///   the `ellipsis` menu with Disconnect, and the detail push.
/// - The agent composer's `+` menu presents it full-screen from
///   `ConversationView.connectionsBrowserPresentation`, in mode
///   `.composerModal`; the screen then supplies its own `NavigationStack`
///   and a Done control. Here the list is where connections are turned on
///   *for the launching chat*: "Connected" / "Discover" / "Status
///   unknown", each Connected row carrying the same per-chat toggle the
///   conversation info section shows, and no Disconnect anywhere (that
///   stays app-wide, in App Settings).
///
/// Section membership is identical in both modes and comes from the
/// catalog alone (`AbilitiesListViewModel.section(for:)`, which is where
/// the status-to-section mapping is spelled out); the mode drives the
/// second header string and the Connected row's accessory.
///
/// A conversation toggle that needs an entitlement no longer deep-links
/// here: it presents the scoped `AbilityConnectSheet` instead, which reuses
/// this screen's view model for the connect machinery.
///
/// Entitled rows push `AbilityDetailScreen` (delegations list) in
/// `.appSettings` only. Available, state-unknown, and `.composerModal`
/// Connected rows stay non-navigable - the last because a `Toggle` inside
/// a `NavigationLink` fights the row's tap target.
struct AbilitiesListView: View {
    @Bindable var viewModel: AbilitiesListViewModel
    /// Latched pair handed down to ability detail pushes.
    let selection: AbilitiesSelection
    /// Drives the second section's header and the Connected accessory.
    var mode: ConnectionsBrowserMode = .appSettings
    /// The per-chat toggle state for `.composerModal`; nil renders the
    /// account-level accessory instead.
    var conversationViewModel: ConversationAbilitiesViewModel?

    var body: some View {
        catalogList
            .searchable(text: $viewModel.searchText, prompt: "Search connections")
            .overlay { listOverlay }
            .task { await viewModel.refresh() }
            .refreshable { await viewModel.refresh() }
            .selfSizingSheet(item: $viewModel.pendingAuthorization, onDismiss: handleAuthorizationDismissed) { context in
                authorizationSheet(context)
            }
    }

    private var catalogList: some View {
        List {
            headerSection
            if viewModel.entitlementsUnavailable {
                unavailableBanner
            }
            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
            }
            nothingConnectedHeroSection
            entitledSection
            availableSection
            unknownStateSection
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .accessibilityIdentifier("abilities-list")
    }

    // MARK: - Chrome

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("Connections")
                    .font(.convosTitle)
                    .tracking(Font.convosTitleTracking)
                    .foregroundStyle(.colorTextPrimary)
                Text("Give agents new powers in your convos")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .listRowBackground(Color.clear)
        }
        .listRowSeparator(.hidden)
        .listRowSpacing(0.0)
        .listRowInsets(.all, DesignConstants.Spacing.step2x)
        .listSectionMargins(.top, 0.0)
        .listSectionSeparator(.hidden)
    }

    /// Shown when the backend served the catalog without entitlement
    /// state. Rows carry last-known state; rows with no last-known state
    /// render in the state-unknown section, never as "not connected".
    /// Carries an explicit retry alongside the list's pull-to-refresh.
    private var unavailableBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.colorLava)
                    Text("Can't check connection status right now. Showing the last-known state.")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                }
                retryButton
            }
            .accessibilityIdentifier("abilities-unavailable-banner")
        }
    }

    /// No retry here on purpose: `errorMessage` is set by connect, disconnect
    /// and delegation failures as well as catalog fetches, and the only retry
    /// this screen can offer is a catalog refetch - which would report success
    /// for a failed connect and clear the message without retrying anything.
    /// The outage banner above is where a refetch is the right action.
    private func errorBanner(_ message: String) -> some View {
        Section {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.colorCaution)
        }
    }

    private var retryButton: some View {
        let action: () -> Void = {
            Task { await viewModel.refresh() }
        }
        return Button(action: action) {
            Text("Retry")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .padding(.vertical, DesignConstants.Spacing.stepX)
                .background(Capsule().fill(Color.colorFillMinimal))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("abilities-retry-button")
    }

    /// The selling-point state for a member with nothing connected yet: a
    /// mosaic of catalog icons over one line of copy, with the available
    /// list right below. When it shows is the view model's call
    /// (`showsNothingConnectedHero`), which withholds it during an outage.
    @ViewBuilder
    private var nothingConnectedHeroSection: some View {
        if viewModel.showsNothingConnectedHero {
            Section {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                    heroIconMosaic
                    // Placeholder copy pending design input.
                    Text("Nothing connected yet. Connect the apps you use and your agent can put them to work.")
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                }
                .padding(.vertical, DesignConstants.Spacing.step2x)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("abilities-nothing-connected-hero")
            }
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
        }
    }

    private var heroIconMosaic: some View {
        let mosaicAbilities: [AbilitiesAPI.Ability] = Array(viewModel.availableAbilities.prefix(5))
        return HStack(spacing: DesignConstants.Spacing.step2x) {
            ForEach(mosaicAbilities) { ability in
                AbilityIconView(ability: ability)
            }
        }
    }

    @ViewBuilder
    private var listOverlay: some View {
        if viewModel.isLoading, !viewModel.hasLoadedOnce {
            ProgressView()
        } else if viewModel.isSearching, !viewModel.hasVisibleAbilities {
            ContentUnavailableView.search(text: viewModel.searchText)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var entitledSection: some View {
        if !viewModel.entitledAbilities.isEmpty {
            Section {
                ForEach(viewModel.entitledAbilities) { ability in
                    entitledRow(ability)
                }
            } header: {
                sectionHeader("Connected")
            }
        }
    }

    @ViewBuilder
    private var availableSection: some View {
        if !viewModel.availableAbilities.isEmpty {
            Section {
                ForEach(viewModel.availableAbilities) { ability in
                    availableRow(ability)
                }
            } header: {
                sectionHeader(availableSectionTitle)
            }
        }
    }

    /// The account-level list enumerates what exists; the chat-scoped one
    /// frames the same rows as things to add to this convo.
    private var availableSectionTitle: String {
        switch mode {
        case .appSettings: "All connections"
        case .composerModal: "Discover"
        }
    }

    /// Outage with no last-known state: the catalog stays browsable but
    /// connect controls are withheld until an authoritative response.
    @ViewBuilder
    private var unknownStateSection: some View {
        if !viewModel.unknownStateAbilities.isEmpty {
            Section {
                ForEach(viewModel.unknownStateAbilities) { ability in
                    unknownStateRow(ability)
                }
            } header: {
                sectionHeader("Status unknown")
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.colorTextSecondary)
    }

    // MARK: - Rows

    @ViewBuilder
    private func entitledRow(_ ability: AbilitiesAPI.Ability) -> some View {
        if let conversationViewModel {
            scopedEntitledRow(ability, conversationViewModel: conversationViewModel)
        } else {
            navigableEntitledRow(ability)
        }
    }

    private func navigableEntitledRow(_ ability: AbilitiesAPI.Ability) -> some View {
        NavigationLink {
            AbilityDetailScreen(ability: ability, selection: selection)
        } label: {
            abilityRowContent(ability, subtitle: entitledSubtitle(for: ability)) {
                entitledAccessory(ability)
            }
        }
    }

    /// Chat-scoped Connected row: status badge plus the shared per-chat
    /// toggle, and nothing else. No `ellipsis` menu (Disconnect is
    /// app-wide, and this surface only extends and withdraws grants) and
    /// no detail push - the toggle needs the row's tap target, and the
    /// push is where a disconnect would sneak back in.
    private func scopedEntitledRow(
        _ ability: AbilitiesAPI.Ability,
        conversationViewModel: ConversationAbilitiesViewModel
    ) -> some View {
        abilityRowContent(ability, subtitle: entitledSubtitle(for: ability)) {
            scopedEntitledAccessory(ability, conversationViewModel: conversationViewModel)
        }
    }

    private func availableRow(_ ability: AbilitiesAPI.Ability) -> some View {
        abilityRowContent(ability, subtitle: ability.subtitle.resolved()) {
            availableAccessory(ability)
        }
    }

    private func unknownStateRow(_ ability: AbilitiesAPI.Ability) -> some View {
        abilityRowContent(ability, subtitle: "Status unavailable") {
            EmptyView()
        }
    }

    private func abilityRowContent(
        _ ability: AbilitiesAPI.Ability,
        subtitle: String,
        @ViewBuilder accessory: () -> some View
    ) -> some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            AbilityIconView(ability: ability)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(ability.displayName.resolved())
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
            accessory()
        }
        .accessibilityIdentifier("ability-row-\(ability.id)")
    }

    /// The entitled row's second line: how broadly the entitlement is in
    /// use, falling back to the server subtitle when unextended.
    private func entitledSubtitle(for ability: AbilitiesAPI.Ability) -> String {
        let count: Int = ability.entitlement?.extensionCount ?? 0
        switch count {
        case 0: return ability.subtitle.resolved()
        case 1: return "Used in 1 convo"
        default: return "Used in \(count) convos"
        }
    }

    // MARK: - Accessories

    @ViewBuilder
    private func entitledAccessory(_ ability: AbilitiesAPI.Ability) -> some View {
        if viewModel.isBusy(ability) {
            ProgressView()
        } else if let entitlement = ability.entitlement {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                AbilityStatusBadge(status: entitlement.status)
                entitledMenu(ability, status: entitlement.status)
            }
        }
    }

    /// The badge still reports the app-wide entitlement status; the toggle
    /// beside it reports this chat. Two different facts, so both render.
    @ViewBuilder
    private func scopedEntitledAccessory(
        _ ability: AbilitiesAPI.Ability,
        conversationViewModel: ConversationAbilitiesViewModel
    ) -> some View {
        if viewModel.isBusy(ability) {
            ProgressView()
        } else {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                if let entitlement = ability.entitlement {
                    AbilityStatusBadge(status: entitlement.status)
                }
                scopedToggle(ability, conversationViewModel: conversationViewModel)
            }
        }
    }

    /// A Connected row the conversation view model has no row for yet is
    /// the catalog arriving ahead of the opt-in read: loading, never a
    /// settled OFF.
    @ViewBuilder
    private func scopedToggle(
        _ ability: AbilitiesAPI.Ability,
        conversationViewModel: ConversationAbilitiesViewModel
    ) -> some View {
        if let row = conversationViewModel.row(forAbilityId: ability.id) {
            let repairAction = { viewModel.connect(ability) }
            ConversationAbilityToggleControl(
                row: row,
                viewModel: conversationViewModel,
                onNeedsAttention: repairAction
            )
        } else {
            ConversationAbilityToggleLoadingControl()
        }
    }

    private func entitledMenu(_ ability: AbilitiesAPI.Ability, status: AbilitiesAPI.EntitlementStatus) -> some View {
        let continueAction = { viewModel.connect(ability) }
        let disconnectAction = { viewModel.disconnect(ability) }
        return Menu {
            switch status {
            case .expired, .needsReauth, .revoked:
                Button("Reconnect", action: continueAction)
            case .active, .pendingAuth:
                // `pendingAuth` never reaches this menu: an unfinished
                // authorization is a Discover row with a Connect button,
                // not a Connected row with a repair entry.
                EmptyView()
            }
            Button("Disconnect", role: .destructive, action: disconnectAction)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .frame(width: DesignConstants.Spacing.step6x, height: DesignConstants.Spacing.step6x)
                .contentShape(.rect)
        }
        .accessibilityIdentifier("ability-menu-\(ability.id)")
    }

    @ViewBuilder
    private func availableAccessory(_ ability: AbilitiesAPI.Ability) -> some View {
        if viewModel.isBusy(ability) {
            ProgressView()
        } else {
            let connectAction = { viewModel.connect(ability) }
            Button(action: connectAction) {
                Text("Connect")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .padding(.vertical, DesignConstants.Spacing.stepX)
                    .background(Capsule().fill(Color.colorFillMinimal))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ability-connect-\(ability.id)")
        }
    }

    // MARK: - Sheets

    private func authorizationSheet(_ context: AbilityAuthorizationContext) -> some View {
        AbilityAuthorizationSheet(
            context: context,
            onAuthorize: { viewModel.completeAuthorization(context) },
            onCancel: { viewModel.cancelAuthorization() }
        )
    }

    /// Fires for every dismissal of the authorization sheet -- Cancel tap,
    /// swipe-down, or programmatic -- so all paths share one cancel
    /// lifecycle in the view model.
    private func handleAuthorizationDismissed() {
        viewModel.handleAuthorizationDismissed()
    }
}

// MARK: - Previews

#Preview("Standard") {
    NavigationStack {
        AbilitiesListScreen(selection: AbilitiesSelection(service: MockAbilitiesService()), mode: .appSettings)
    }
}

#Preview("Composer modal") {
    AbilitiesListScreen(
        selection: AbilitiesSelection(service: MockAbilitiesService()),
        mode: .composerModal(conversationId: "mock-conversation-1", agentInboxId: "mock-agent-inbox-1", agentDisplayName: "Caley")
    )
}

#Preview("Entitlements unavailable") {
    NavigationStack {
        AbilitiesListScreen(selection: AbilitiesSelection(service: MockAbilitiesService(scenario: .entitlementsUnavailable)), mode: .appSettings)
    }
}

#Preview("Cold-start outage") {
    NavigationStack {
        AbilitiesListScreen(selection: AbilitiesSelection(service: MockAbilitiesService(scenario: .entitlementsUnavailableColdStart)), mode: .appSettings)
    }
}

#Preview("Device only") {
    NavigationStack {
        AbilitiesListScreen(selection: AbilitiesSelection(service: MockAbilitiesService(scenario: .deviceOnly)), mode: .appSettings)
    }
}
