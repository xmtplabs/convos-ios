import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import ConvosMetrics

private struct SafariTestSheet: View {
    @State private var safariURL: URL?

    var body: some View {
        VStack(spacing: 20) {
            Text("Safari in Sheet Test")
                .font(.title2)
                .bold()

            Text("Tap the button below to open convos.org in an in-app Safari view. This tests that .safariSheet works from inside a presented sheet.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            let action = { safariURL = URL(string: "https://convos.org") }
            Button(action: action) {
                Text("Open convos.org")
            }
            .convosButtonStyle(.rounded(fullWidth: true))
        }
        .padding(30)
        .safariSheet(url: $safariURL)
    }
}
import Sentry
import SwiftUI
import UIKit

struct DebugViewSection: View {
    let environment: AppEnvironment
    let session: any SessionManagerProtocol
    let coreActions: any CoreActions
    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationAuthGranted: Bool = false
    @State private var lastDeviceToken: String = ""
    @State private var isRenewingAssets: Bool = false
    @State private var renewalAlertMessage: String?
    @State private var showingRenewalAlert: Bool = false
    @State private var presentingPhotosInfoSheet: Bool = false
    @State private var logStorageInfo: DebugLogExporter.LogStorageInfo?
    @State private var showingAgentsInfoSheet: Bool = false
    @State private var showingSafariTestSheet: Bool = false
    @State private var presentingPaywall: Bool = false
    @State private var creditsPresetSelection: CreditsStatePreset = FeatureFlags.shared.mockCreditsPreset
    @State private var useRealStoreKit: Bool = SubscriptionServices.useRealStoreKit
    @State private var useRealCredits: Bool = CreditsServices.useRealBackend
    @State private var identity: DeviceIdentitySnapshot?
    @State private var docAgentBindingId: String?
    @State private var docAgentDiagnostic: AgentJoinDiagnostic?
    @State private var didResetDocAgent: Bool = false
    @State private var isResettingDocAgent: Bool = false
    @State private var docVariantResolution: DocModeVariantResolver.Resolution?
    @State private var isResolvingDocMode: Bool = false
    @State private var isDocModeEnabled: Bool = FeatureFlags.shared.isDocModeEnabled
    @State private var docModeErrorMessage: String?

    var body: some View {
        Group {
            featuresSection
            docSection
            subscriptionSection
            pushNotificationsSection
            debugSection
            authProbeSection
            sentryTestingSection
            pendingInvitesSection
            assetRenewalSection
            sheetsSection
            resetSection
        }
        .task {
            await refreshNotificationStatus()
            logStorageInfo = DebugLogExporter.getStorageInfo(environment: environment)
            let identityStore = KeychainIdentityStore(accessGroup: environment.keychainAccessGroup)
            identity = await DeviceIdentitySnapshot.current(identityStore: identityStore)
            refreshDocAgentDiagnostic()
            await refreshDocVariantResolution()
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .agentJoinDiagnosticsDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            refreshDocAgentDiagnostic()
        }
    }

    @ViewBuilder
    private var featuresSection: some View {
        Section("Features") {
            Toggle("Debug injector button", isOn: Bindable(FeatureFlags.shared).isDebugInjectorEnabled)
            agentVariantToggles
            Toggle("XMTP bidi streaming (applies next launch)", isOn: Bindable(FeatureFlags.shared).isXMTPBidiStreamsEnabled)
            Toggle("Share Space (copy import link)", isOn: Bindable(FeatureFlags.shared).isSpaceShareEnabled)
            Toggle("Web inspector (space/browser web views)", isOn: Bindable(FeatureFlags.shared).isWebInspectorEnabled)
            Toggle("Enable Relay (BYOA)", isOn: Bindable(FeatureFlags.shared).agentRelayEnabled)
            Toggle("Agent model picker", isOn: Bindable(FeatureFlags.shared).isAgentModelPickerEnabled)

            let showInfoAction = { showingAgentsInfoSheet = true }
            Button(action: showInfoAction) {
                Text("Show Agents Info Sheet")
            }
            .selfSizingSheet(isPresented: $showingAgentsInfoSheet) {
                AgentsInfoView()
                    .padding(.top, 20)
            }

            let testSafariAction = { showingSafariTestSheet = true }
            Button(action: testSafariAction) {
                Text("Test Safari Sheet in Sheet")
            }
            .sheet(isPresented: $showingSafariTestSheet) {
                SafariTestSheet()
            }
        }
    }

    /// The agent-variant flag. The toggle gates the picker at conversation
    /// creation, including the Doc launch below, and the dropdown in the
    /// make-an-agent composer.
    @ViewBuilder
    private var agentVariantToggles: some View {
        Toggle("Agent variant selector", isOn: Bindable(FeatureFlags.shared).isAgentVariantSelectorEnabled)
    }

    @ViewBuilder
    private var docSection: some View {
        Section("Doc") {
            Toggle("Doc mode", isOn: $isDocModeEnabled)
                .disabled(isResolvingDocMode)
                .onChange(of: isDocModeEnabled) { _, enabled in
                    setDocMode(enabled)
                }

            if let docModeErrorMessage {
                Text(docModeErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("doc-mode-error")
            }

            LabeledContent("Variant") {
                Text(selectedDocVariantDescription)
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }

            LabeledContent("Runtime") {
                VStack(alignment: .trailing, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(docAgentVariantDescription)
                        .foregroundStyle(.colorTextSecondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                    Text(docAgentVariantDroppedDescription)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
            }

            let resetDocAgentAction = { resetDocAgent() }
            Button(action: resetDocAgentAction) {
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    if isResettingDocAgent {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isResettingDocAgent ? "Resetting Doc agent…" : "Reset Doc agent")
                }
                    .foregroundStyle(.colorTextPrimary)
            }
            .disabled(!canResetDocAgent || isResettingDocAgent)

            if didResetDocAgent {
                Label("Reset — reopen Doc to start over", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .accessibilityIdentifier("doc-agent-reset-confirmation")
            }
        }
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        Section("Subscription") {
            DebugRevealableValueRow(label: "Account ID", value: identity?.accountId)
            DebugRevealableValueRow(label: "Inbox ID", value: identity?.inboxId)
            Toggle("Use real StoreKit", isOn: $useRealStoreKit)
                .onChange(of: useRealStoreKit) { _, newValue in
                    SubscriptionServices.setUseRealStoreKit(newValue)
                }
            Toggle("Use real backend credits", isOn: $useRealCredits)
                .onChange(of: useRealCredits) { _, newValue in
                    CreditsServices.setUseRealBackend(newValue)
                }

            if !useRealStoreKit && !useRealCredits {
                Picker("Credits state", selection: $creditsPresetSelection) {
                    ForEach(CreditsStatePreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .onChange(of: creditsPresetSelection) { _, newValue in
                    FeatureFlags.shared.mockCreditsPreset = newValue
                    MockCreditsService.shared.setPreset(newValue)
                    MockSubscriptionService.shared.setPreset(newValue)
                }
            }

            NavigationLink {
                SubscriptionSettingsView(coreActions: coreActions)
            } label: {
                Text("Credits & Subscription Details")
                    .foregroundStyle(.colorTextPrimary)
            }

            let openPaywallAction = { presentingPaywall = true }
            Button(action: openPaywallAction) {
                Text("Show Paywall")
                    .foregroundStyle(.colorTextPrimary)
            }
            .sheet(isPresented: $presentingPaywall) {
                let viewModel = PaywallViewModel(
                    subscriptionService: SubscriptionServices.shared,
                    paywallSource: .debug,
                    coreActions: coreActions
                )
                PaywallView(viewModel: viewModel)
            }
        }
    }

    @ViewBuilder
    private var pushNotificationsSection: some View {
        Section(header: Text("Push Notifications")) {
            HStack {
                Text("Auth Status")
                Spacer()
                Text(statusText(notificationAuthStatus))
                    .foregroundStyle(.colorTextSecondary)
            }
            HStack {
                Text("Authorized")
                Spacer()
                Text(notificationAuthGranted ? "Yes" : "No")
                    .foregroundStyle(.colorTextSecondary)
            }
            deviceTokenRow
            HStack {
                Text("APNS Environment")
                Spacer()
                Text(ConfigManager.shared.currentEnvironment.apnsEnvironment.rawValue)
                    .foregroundStyle(.colorTextSecondary)
            }
            HStack {
                Button("Request Now") {
                    Task { await requestNotificationsNow() }
                }
                .disabled(notificationAuthGranted)
                .opacity(notificationAuthGranted ? 0.5 : 1.0)
            }
        }
    }

    @ViewBuilder
    private var deviceTokenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Device Token")
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(lastDeviceToken)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.colorTextSecondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button {
                    UIPasteboard.general.string = lastDeviceToken
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(lastDeviceToken.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var debugSection: some View {
        Section("Debug") {
            HStack {
                Text("Bundle ID")
                Spacer()
                Text(Bundle.main.bundleIdentifier ?? "Unknown")
                    .foregroundStyle(.colorTextSecondary)
            }

            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.appVersion)
                    .foregroundStyle(.colorTextSecondary)
            }

            HStack {
                Text("Environment")
                Spacer()
                Text(ConfigManager.shared.currentEnvironment.name.capitalized)
                    .foregroundStyle(.colorTextSecondary)
            }

            HStack {
                Text("Log storage")
                Spacer()
                if let info = logStorageInfo {
                    Text(info.formattedTotalSize)
                        .foregroundStyle(.colorTextSecondary)
                } else {
                    ProgressView()
                }
            }

            postHogTokenRow
        }
    }

    @ViewBuilder
    private var postHogTokenRow: some View {
        let token: String = Secrets.POSTHOG_API_KEY
        VStack(alignment: .leading, spacing: 6) {
            Text("PostHog Project Token")
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(token.isEmpty ? "(not set)" : token)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.colorTextSecondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button {
                    UIPasteboard.general.string = token
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(token.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var authProbeSection: some View {
        Section("SIWE Auth") {
            NavigationLink {
                DebugAuthProbeView(environment: environment)
            } label: {
                Text("Run SIWE Auth Probe")
                    .foregroundStyle(.colorTextPrimary)
            }
        }
    }

    @ViewBuilder
    private var sentryTestingSection: some View {
        Section("Sentry Testing") {
            Button {
                testSentryMessage()
            } label: {
                Text("Send Test Message")
                    .foregroundStyle(.colorTextPrimary)
            }
            Button {
                testSentryError()
            } label: {
                Text("Send Test Error")
                    .foregroundStyle(.colorTextPrimary)
            }
            Button {
                testSentryException()
            } label: {
                Text("Send Test Exception")
                    .foregroundStyle(.colorTextPrimary)
            }
            Button {
                testSentryWithBreadcrumbs()
            } label: {
                Text("Send Event with Breadcrumbs")
                    .foregroundStyle(.colorTextPrimary)
            }
        }
    }

    @ViewBuilder
    private var pendingInvitesSection: some View {
        Section("Pending Invites") {
            NavigationLink {
                PendingInviteDebugView(session: session)
            } label: {
                Text("View Pending Invites")
                    .foregroundStyle(.colorTextPrimary)
            }
            NavigationLink {
                OrphanedInboxDebugView(session: session)
            } label: {
                Text("View Orphaned Inboxes")
                    .foregroundStyle(.colorTextPrimary)
            }
        }
    }

    @ViewBuilder
    private var assetRenewalSection: some View {
        Section("Asset Renewal") {
            NavigationLink {
                DebugAssetRenewalView(session: session)
            } label: {
                Text("View Renewable Assets")
                    .foregroundStyle(.colorTextPrimary)
            }

            Button {
                Task { await renewAssetsNow() }
            } label: {
                HStack {
                    Text("Renew Assets Now")
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    if isRenewingAssets { ProgressView() }
                }
            }
            .disabled(isRenewingAssets)
        }
        .alert("Asset Renewal", isPresented: $showingRenewalAlert, presenting: renewalAlertMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var sheetsSection: some View {
        Section("Sheets") {
            Button {
                presentingPhotosInfoSheet = true
            } label: {
                Text("Show Photos Info Sheet")
                    .foregroundStyle(.colorTextPrimary)
            }
        }
        .selfSizingSheet(isPresented: $presentingPhotosInfoSheet) {
            PhotosInfoSheet()
        }
    }

    @ViewBuilder
    private var resetSection: some View {
        Section {
            Button {
                Task { await registerDeviceAgain() }
            } label: {
                Text("Register Device Again")
                    .foregroundStyle(.colorTextPrimary)
            }
            Button {
                resetOnboarding()
            } label: {
                Text("Reset Onboarding")
                    .foregroundStyle(.colorTextPrimary)
            }
            Button {
                resetAllSettings()
            } label: {
                Text("Reset All Settings")
                    .foregroundStyle(.colorTextPrimary)
            }
        }
    }

    private var docAgentVariantDescription: String {
        guard let variant = docAgentDiagnostic?.variant else { return "none — default agent" }
        let commit = variant.commit.isEmpty ? "unknown" : String(variant.commit.prefix(10))
        return "\(variant.slug) @ \(commit)"
    }

    private var selectedDocVariantDescription: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DocDiagnosticPreview") {
            return "Doc · pr-3655"
        }
        #endif
        if isResolvingDocMode { return "Checking registry…" }
        switch docVariantResolution {
        case .notRegistered:
            return "No Doc variant registered"
        case .unavailable:
            return "Registry unavailable"
        case .resolved(let variant):
            return "\(variant.label) · \(variant.slug)"
        case nil:
            guard let variant = FeatureFlags.shared.selectedAgentVariant,
                  variant.label == "Doc" else {
                return "No Doc variant selected"
            }
            return "\(variant.label) · \(variant.slug)"
        }
    }

    private var docAgentVariantDroppedDescription: String {
        guard let docAgentDiagnostic else { return "No join response recorded" }
        let requested = docAgentDiagnostic.requestedVariantId ?? "none"
        let dropped = docAgentDiagnostic.variantDropped ?? "none"
        return "requested: \(requested) · variantDropped: \(dropped)"
    }

    private func refreshDocAgentDiagnostic() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DocDiagnosticPreview") {
            docAgentBindingId = "doc-preview-conversation"
            docAgentDiagnostic = AgentJoinDiagnostic(
                conversationId: "doc-preview-conversation",
                requestedVariantId: "pr-3655",
                variant: .init(slug: "pr-3655", commit: "abc123def456"),
                variantDropped: nil
            )
            return
        }
        #endif
        docAgentBindingId = DocExperienceViewModel.storedOriginConversationId(session: session)
        docAgentDiagnostic = docAgentBindingId.flatMap {
            AgentJoinDiagnosticsStore.shared.diagnostic(for: $0)
        }
    }

    private func resetDocAgent() {
        guard !isResettingDocAgent else { return }
        didResetDocAgent = false
        isResettingDocAgent = true
        Task {
            await DocExperienceViewModel.resetAgentBinding(session: session)
            docAgentBindingId = nil
            docAgentDiagnostic = nil
            isResettingDocAgent = false
            didResetDocAgent = true
        }
    }

    private func setDocMode(_ enabled: Bool) {
        if !enabled {
            FeatureFlags.shared.isDocModeEnabled = false
            return
        }
        guard !isResolvingDocMode else { return }
        docModeErrorMessage = nil
        isResolvingDocMode = true
        Task {
            let resolution = await DocModeVariantResolver.resolve(forceRefresh: true)
            docVariantResolution = resolution
            if let errorMessage = DocModeResolutionPolicy.enablementError(for: resolution) {
                docModeErrorMessage = errorMessage
                FeatureFlags.shared.isDocModeEnabled = false
                isDocModeEnabled = false
            } else if case .resolved(let variant) = resolution {
                await convergeDocAgent(to: variant)
                FeatureFlags.shared.isDocModeEnabled = true
            }
            isResolvingDocMode = false
        }
    }

    private func refreshDocVariantResolution() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DocDiagnosticPreview") {
            return
        }
        #endif
        if FeatureFlags.shared.isDocModeEnabled {
            docVariantResolution = await DocModeVariantResolver.resolve()
            return
        }
        await AgentVariantRegistry.shared.loadIfNeeded()
        guard AgentVariantRegistry.shared.loadState == .loaded else {
            docVariantResolution = .unavailable
            return
        }
        if let variant = AgentVariantRegistry.shared.mostRecentlyRegisteredVariant(labeled: "Doc") {
            docVariantResolution = .resolved(variant)
        } else {
            docVariantResolution = .notRegistered
        }
    }

    private func convergeDocAgent(to variant: ConvosAPI.AgentVariant) async {
        let action = DocAgentConvergenceAction.resolve(
            conversationId: docAgentBindingId,
            diagnostic: docAgentDiagnostic,
            expectedVariantSlug: variant.slug
        )
        guard action == .replace else { return }
        await DocExperienceViewModel.resetAgentBindingForVariantConvergence(session: session)
        docAgentBindingId = nil
        docAgentDiagnostic = nil
        didResetDocAgent = false
    }

    private var canResetDocAgent: Bool {
        docAgentBindingId != nil || session.peekPreparedConversationId() != nil
    }
}

#Preview {
    List {
        DebugViewSection(environment: .tests, session: MockInboxesService(), coreActions: NoOpCoreActions())
    }
}

// MARK: - Push helpers

extension DebugViewSection {
    private func statusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthStatus = settings.authorizationStatus
        notificationAuthGranted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        lastDeviceToken = PushNotificationRegistrar.token ?? ""
    }

    private func requestNotificationsNow() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            }
            await refreshNotificationStatus()
        } catch {
            Log.error("Debug push request failed: \(error)")
        }
    }

    private func registerDeviceAgain() async {
        let apnsEnv = ConfigManager.shared.currentEnvironment.apnsEnvironment.rawValue
        Log.info("Debug: Force re-registering device (APNS env: \(apnsEnv))")

        // The original implementation called `PlatformProviders.iOS` here, which
        // constructs a fresh `IOSPushNotificationRegistrar` whose in-memory token
        // is nil. That made the debug button race against the real app's state
        // and could register the device with `pushToken: nil` even when the
        // device had a valid token. Reuse the already-configured singletons so
        // the debug action sees the SAME APNS token, deviceId, and registrar
        // state the app uses everywhere else.
        //
        // `ConvosCore.DeviceInfo` is fully qualified because the main app has
        // its own `DeviceInfo` struct in Utilities & Extensions that shadows
        // the ConvosCore enum at this call site.
        let deviceInfo = ConvosCore.DeviceInfo.shared
        let providersForDebug = PlatformProviders(
            appLifecycle: MockAppLifecycleProvider(),
            deviceInfo: deviceInfo,
            pushNotificationRegistrar: PushNotificationRegistrar.shared,
            notificationCenter: UNUserNotificationCenter.current()
        )
        DeviceRegistrationManager.clearRegistrationState(deviceInfo: deviceInfo)

        let manager = DeviceRegistrationManager(
            environment: ConfigManager.shared.currentEnvironment,
            platformProviders: providersForDebug
        )
        await manager.registerDeviceIfNeeded()
    }

    private func resetOnboarding() {
        ConversationOnboardingCoordinator().reset()
    }

    private func renewAssetsNow() async {
        guard !isRenewingAssets else { return }
        isRenewingAssets = true

        let renewalManager = await session.makeAssetRenewalManager()
        let result = await renewalManager.forceRenewal()

        isRenewingAssets = false

        if let result {
            renewalAlertMessage = "Renewed: \(result.renewed)\nFailed: \(result.failed)\nExpired: \(result.expiredKeys.count)"
        } else {
            renewalAlertMessage = "Renewal failed. Check logs for details."
        }
        showingRenewalAlert = true
    }

    private func resetAllSettings() {
        ConversationViewModel.resetUserDefaults()
        ConversationsViewModel.resetUserDefaults()
        ConversationOnboardingCoordinator.resetUserDefaults()
        GlobalConvoDefaults.shared.reset()
    }

    func testSentryMessage() {
        let message = "Test message from local development - \(Date())"
        SentrySDK.capture(message: message)
        Log.info("Sent Sentry test message: \(message)")
    }

    func testSentryError() {
        let error = NSError(
            domain: "com.convos.debug",
            code: 999,
            userInfo: [
                NSLocalizedDescriptionKey: "Test error for Sentry debugging",
                "timestamp": Date().ISO8601Format(),
                "environment": ConfigManager.shared.currentEnvironment.name
            ]
        )
        SentrySDK.capture(error: error)
        Log.info("Sent Sentry test error")
    }

    func testSentryException() {
        let exception = NSException(
            name: .init("TestException"),
            reason: "Test exception from local debug view",
            userInfo: [
                "user_action": "debug_test",
                "timestamp": Date().ISO8601Format()
            ]
        )
        SentrySDK.capture(exception: exception)
        Log.info("Sent Sentry test exception")
    }

    func testSentryWithBreadcrumbs() {
        let crumb1 = Breadcrumb(level: .info, category: "navigation")
        crumb1.message = "User navigated to Debug view"
        crumb1.data = ["screen": "DebugView"]
        SentrySDK.addBreadcrumb(crumb1)

        let crumb2 = Breadcrumb(level: .info, category: "user_action")
        crumb2.message = "User tapped Sentry test button"
        crumb2.data = ["action": "test_breadcrumbs"]
        SentrySDK.addBreadcrumb(crumb2)

        SentrySDK.capture(message: "Event with breadcrumbs - \(Date())")
        Log.info("Sent Sentry event with breadcrumbs")
    }
}
