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
            NavigationLink {
                MyInfoView(
                    profile: .constant(.empty()),
                    profileImage: .constant(nil),
                    editingDisplayName: .constant(""),
                    profileSettingsViewModel: profileSettingsViewModel,
                    showsCancelButton: false,
                    showsProfile: false,
                    showsUseProfileButton: false,
                    canEditProfile: true
                ) { _ in }
                .onAppear { navigator?.navigateTo(myInfo: MyInfoNavigatorArgs()) }
            } label: {
                myInfoRowLabel
            }
            .accessibilityIdentifier("my-info-row")
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

    @ViewBuilder
    private var myInfoRowLabel: some View {
        HStack {
            Image(systemName: "lanyardcard.fill")
                .foregroundStyle(.colorTextPrimary)
                .frame(width: DesignConstants.Spacing.step8x, alignment: .center)

            Text("My info")
                .foregroundStyle(.colorTextPrimary)

            Spacer()

            if !profileSettingsViewModel.profileSettings.isDefault {
                Text(profileSettingsViewModel.editingDisplayName)
                    .foregroundStyle(.colorTextSecondary)

                ProfileAvatarView(
                    profile: profileSettingsViewModel.profile,
                    profileImage: profileSettingsViewModel.profileImage,
                    useSystemPlaceholder: false
                )
                .frame(width: 16.0, height: 16.0)
            }
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
        Section {
            privacyTermsRow
            sendFeedbackRow
            if !ConfigManager.shared.currentEnvironment.isProduction {
                debugRow
            }
        } footer: {
            linksFooter
        }
        .listRowSeparatorTint(.colorBorderSubtle)
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
    private var linksFooter: some View {
        HStack {
            Text("Made in the open by XMTP Labs")
            Spacer()
            Text("V\(Bundle.appVersion)")
                .foregroundStyle(.colorTextTertiary)
        }
        .foregroundStyle(.colorTextSecondary)
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
