import ConvosComposer
import ConvosCore
import ConvosMetrics
import SwiftUI

struct ConvosToolbarButton: View {
    let padding: Bool
    let action: () -> Void
    var statusLabel: String = "Basic"
    var statusColor: Color = .colorTextSecondary
    var showsBoltIcon: Bool = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Image("convosOrangeIcon")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.colorFillPrimary)
                    .frame(width: 16.0, height: 20.0)
                    .frame(width: 24.0, height: 24.0)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Convos")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.colorFillPrimary)
                    statusLine
                }
                .padding(.trailing, DesignConstants.Spacing.stepX)
            }
            .padding(padding ? DesignConstants.Spacing.step2x : 0)
        }
        .accessibilityIdentifier("convos-logo-button")
    }

    @ViewBuilder
    private var statusLine: some View {
        if showsBoltIcon {
            HStack(spacing: 2) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                Text(statusLabel)
                    .font(.system(size: 12))
            }
            .foregroundStyle(statusColor)
        } else {
            Text(statusLabel)
                .font(.system(size: 12))
                .foregroundStyle(statusColor)
        }
    }
}

struct AppSettingsView: View {
    @Bindable var viewModel: AppSettingsViewModel
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    let session: any SessionManagerProtocol
    let coreActions: any CoreActions
    let onDeleteAllData: () -> Void
    @State private var showingDeleteAllDataConfirmation: Bool = false
    @Environment(\.openURL) private var openURL: OpenURLAction
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var navState: AppSettingsNavigatorImpl = .init()
    @State private var navigator: AppSettingsCollector?
    @State private var versionTapCount: Int = 0
    @State private var lastVersionTapAt: Date?
    @State private var showingEnableDebugConfirmation: Bool = false
    @State private var presentingMyInfoSheet: Bool = false

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = AppSettingsCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    private func handlePaywallPresented(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(paywall: PaywallNavigatorArgs(source: .settings))
    }

    private func handleDeleteAllDataPresented(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.navigateTo(deleteAllData: DeleteAllDataNavigatorArgs())
    }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                myInfoSection
                subscriptionSection
                connectionsSection
                devicesSection
                customizeSection
                linksSection
                deleteSection
            }
            .scrollContentBackground(.hidden)
            .background(.colorBackgroundRaisedSecondary)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .contentMargins(.top, 0.0)
            .toolbarTitleDisplayMode(.inline)
            .toolbar { topToolbar }
            .onReceive(CreditsServices.shared.balancePublisher) { creditBalance = $0 }
            .onReceive(SubscriptionServices.shared.subscriptionPublisher) { currentSubscription = $0 }
            .onAppear {
                ensureNavigator()
                navState.markScreenAppeared()
            }
            .onDisappear {
                navigator?.closed(context: navState.closeContext())
            }
            .onChange(of: presentingPaywall) { oldValue, newValue in
                handlePaywallPresented(from: oldValue, to: newValue)
            }
            .onChange(of: showingDeleteAllDataConfirmation) { oldValue, newValue in
                handleDeleteAllDataPresented(from: oldValue, to: newValue)
            }
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("Convos")
                    .font(.convosTitle)
                    .tracking(Font.convosTitleTracking)
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

    @ViewBuilder
    private var myInfoSection: some View {
        Section {
            Button {
                presentingMyInfoSheet = true
                navigator?.navigateTo(myInfo: MyInfoNavigatorArgs())
            } label: {
                myInfoRowLabel
            }
            .accessibilityIdentifier("my-info-row")
            .accessibilityLabel("My info")
            .accessibilityValue(
                profileSettingsViewModel.editingDisplayName.isEmpty
                    ? "Not set"
                    : profileSettingsViewModel.editingDisplayName
            )
            .listRowInsets(.all, DesignConstants.Spacing.step2x)
            .sheet(isPresented: $presentingMyInfoSheet) {
                ProfileSetupSheet(mode: .edit)
            }
        } footer: {
            Text("Your name and pic")
        }
    }

    @ViewBuilder
    private var devicesSection: some View {
        Section {
            NavigationLink {
                DevicesView(
                    viewModel: DevicesViewModel(
                        pairingServiceFactory: { [session] in
                            DeferredInitiatorPairingService(session: session)
                        },
                        session: session,
                        appGroupIdentifier: ConfigManager.shared.currentEnvironment.appGroupIdentifier
                    )
                )
                .onAppear { navigator?.navigateTo(devices: DevicesNavigatorArgs()) }
            } label: {
                HStack {
                    Image(systemName: "iphone.gen3.sizes")
                        .foregroundStyle(.colorTextPrimary)
                        .frame(width: DesignConstants.Spacing.step8x, alignment: .center)
                    Text("Devices")
                        .foregroundStyle(.colorTextPrimary)
                }
            }
            .accessibilityIdentifier("devices-row")
        } footer: {
            Text("Manage and pair other devices")
        }
    }

    /// Mirrors the profile sheet's name row: avatar, name, and a trailing
    /// pencil affordance. Tapping anywhere opens the profile sheet.
    @ViewBuilder
    private var myInfoRowLabel: some View {
        let displayName = profileSettingsViewModel.editingDisplayName
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Group {
                if !displayName.isEmpty || profileSettingsViewModel.profileImage != nil {
                    ProfileAvatarView(
                        profile: profileSettingsViewModel.profile,
                        profileImage: profileSettingsViewModel.profileImage,
                        useSystemPlaceholder: false
                    )
                } else {
                    ZStack {
                        Circle().fill(.colorBackgroundInverted)
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 20.0))
                            .foregroundStyle(.colorTextPrimaryInverted)
                    }
                }
            }
            .frame(width: 36.0, height: 36.0)

            Text(displayName.isEmpty ? "Name" : displayName)
                .font(.body)
                .foregroundStyle(displayName.isEmpty ? .colorTextTertiary : .colorTextPrimary)

            Spacer()

            Image(systemName: "pencil")
                .font(.body.weight(.medium))
                .foregroundStyle(.colorTextSecondary)
                .padding(.trailing, DesignConstants.Spacing.step2x)
        }
    }

    @ViewBuilder
    private var connectionsSection: some View {
        Section {
            NavigationLink {
                ConnectionsListView(viewModel: viewModel.connectionsListViewModel)
                    .onAppear { navigator?.navigateTo(connections: ConnectionsNavigatorArgs()) }
            } label: {
                connectionsRowLabel
            }
            .accessibilityIdentifier("connections-row")
        } footer: {
            Text("Apps and info agents can use")
        }
    }

    @ViewBuilder
    private var connectionsRowLabel: some View {
        let connectionsCount: Int = viewModel.connectionsListViewModel.connections.count
        HStack {
            Image(systemName: "batteryblock.fill")
                .foregroundStyle(.colorTextPrimary)
                .frame(width: DesignConstants.Spacing.step8x, alignment: .center)

            Text("Connections")
                .foregroundStyle(.colorTextPrimary)

            Spacer()

            if connectionsCount > 0 {
                Text("\(connectionsCount)")
                    .foregroundStyle(.colorTextSecondary)
                    .monospacedDigit()
            }
        }
    }

    @State private var presentingPaywall: Bool = false
    @State private var creditBalance: CreditBalance? = CreditsServices.shared.currentBalance
    @State private var currentSubscription: UserSubscription? = SubscriptionServices.shared.currentSubscription

    private var membershipFooterLabel: String {
        if currentSubscription != nil { return "Plus membership" }
        return "Basic membership"
    }

    private var isPowerDepleted: Bool {
        creditBalance?.isDepleted == true
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        Section {
            let subscribeAction = { presentingPaywall = true }
            Button(action: subscribeAction) {
                powerRowLabel
            }
            .accessibilityIdentifier("subscription-row")
            .sheet(isPresented: $presentingPaywall) {
                let viewModel = PaywallViewModel(
                    subscriptionService: SubscriptionServices.shared,
                    paywallSource: .settings,
                    coreActions: coreActions
                )
                PaywallView(viewModel: viewModel)
            }
        } footer: {
            Text(membershipFooterLabel)
        }
    }

    @ViewBuilder
    private var powerRowLabel: some View {
        HStack {
            Image(systemName: "bolt.fill")
                .foregroundStyle(.colorTextPrimary)
                .frame(width: DesignConstants.Spacing.step8x, alignment: .center)

            Text("Power")
                .foregroundStyle(.colorTextPrimary)

            Spacer()

            if isPowerDepleted {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.colorLava)
            }
        }
    }

    @ViewBuilder
    private var customizeSection: some View {
        Section {
            NavigationLink {
                CustomizeSettingsView()
                    .onAppear { navigator?.navigateTo(customize: CustomizeSettingsNavigatorArgs()) }
            } label: {
                Text("Customize")
                    .foregroundStyle(.colorTextPrimary)
            }
        }
        .listRowSeparatorTint(.colorBorderSubtle)
    }

    @ViewBuilder
    private var linksSection: some View {
        let environment: AppEnvironment = ConfigManager.shared.currentEnvironment
        let showsFullMenu: Bool = DebugMenuGate.showsFullDebugMenu(for: environment)
        Section {
            privacyTermsRow
            sendFeedbackRow
            if showsFullMenu {
                debugRow
            } else if DebugMenuGate.showsProdDebugMenu(for: environment) {
                prodDebugRow
            }
        } footer: {
            linksFooter
        }
        .listRowSeparatorTint(.colorBorderSubtle)
        .confirmationDialog(
            "Enable debug menu?",
            isPresented: $showingEnableDebugConfirmation,
            titleVisibility: .visible
        ) {
            // Persist the opt-in. Dismissing the dialog flips
            // `showingEnableDebugConfirmation` back to false, which re-renders
            // the body so `linksSection` re-reads the gate and reveals the row.
            let enableAction = { DebugMenuFlagStore.enable() }
            Button("Enable", action: enableAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reveals on-device diagnostics for this account. You can turn it off any time from the debug menu.")
        }
    }

    @ViewBuilder
    private var privacyTermsRow: some View {
        Button {
            openExternalURL("https://hq.convos.org/privacy-and-terms")
        } label: {
            NavigationLink("Privacy & Terms", destination: EmptyView())
        }
        .foregroundStyle(.colorTextPrimary)
    }

    @ViewBuilder
    private var sendFeedbackRow: some View {
        Button {
            sendFeedback()
        } label: {
            Text("Send feedback")
        }
        .foregroundStyle(.colorTextPrimary)
    }

    @ViewBuilder
    private var debugRow: some View {
        NavigationLink {
            DebugExportView(environment: ConfigManager.shared.currentEnvironment, session: session, coreActions: coreActions)
        } label: {
            Text("Debug")
        }
        .foregroundStyle(.colorTextPrimary)
    }

    @ViewBuilder
    private var prodDebugRow: some View {
        NavigationLink {
            ProdDebugMenuView(environment: ConfigManager.shared.currentEnvironment, session: session)
        } label: {
            Text("Debug menu")
        }
        .foregroundStyle(.colorTextPrimary)
        .accessibilityIdentifier("prod-debug-menu-row")
    }

    @ViewBuilder
    private var linksFooter: some View {
        HStack {
            Text("Made in the open by XMTP Labs")
            Spacer()
            let versionTapAction = { handleVersionTapped() }
            Button(action: versionTapAction) {
                Text("v\(Bundle.appVersion)")
                    .foregroundStyle(.colorTextTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-version-label")
        }
        .foregroundStyle(.colorTextSecondary)
    }

    private func handleVersionTapped() {
        let environment: AppEnvironment = ConfigManager.shared.currentEnvironment
        // Non-production already shows the full debug menu, so the easter-egg
        // gesture only matters in production where the curated menu is opt-in.
        // Read the persisted flag directly (not a cached copy) so a menu that
        // was disabled elsewhere can be re-enabled without relaunching.
        guard environment.isProduction, !DebugMenuFlagStore.isEnabled() else { return }
        let now = Date()
        if let lastTap = lastVersionTapAt, now.timeIntervalSince(lastTap) > Constant.versionTapWindow {
            versionTapCount = 0
        }
        lastVersionTapAt = now
        versionTapCount += 1
        if versionTapCount >= Constant.versionTapThreshold {
            versionTapCount = 0
            showingEnableDebugConfirmation = true
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showingDeleteAllDataConfirmation = true
            } label: {
                Text("Delete all app data")
            }
            .accessibilityLabel("Delete all app data")
            .accessibilityHint("Permanently deletes all conversations and your profile")
            .accessibilityIdentifier("delete-all-data-button")
            .selfSizingSheet(isPresented: $showingDeleteAllDataConfirmation) {
                DeleteAllDataView(
                    viewModel: viewModel,
                    onComplete: {
                        dismiss()
                        onDeleteAllData()
                    }
                )
                .interactiveDismissDisabled(viewModel.isDeleting)
            }
        }
    }

    @ToolbarContentBuilder
    private var topToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .cancel) {
                dismiss()
            }
        }
    }

    private func sendFeedback() {
        let email = "hi@convos.org"
        let subject = "Convos Feedback"
        let mailtoString = "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject)"

        if let mailtoURL = URL(string: mailtoString) {
            openURL(mailtoURL)
        }
    }

    private func openExternalURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        openURL(url)
    }

    private enum Constant {
        static let versionTapThreshold: Int = 7
        static let versionTapWindow: TimeInterval = 3
    }
}

#Preview {
    let profileSettingsViewModel = ProfileSettingsViewModel.shared
    NavigationStack {
        AppSettingsView(
            viewModel: .mock,
            profileSettingsViewModel: profileSettingsViewModel,
            session: MockInboxesService(),
            coreActions: NoOpCoreActions(),
            onDeleteAllData: {}
        )
    }
}
