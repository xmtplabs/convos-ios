import ConvosCore
import ConvosCoreiOS

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
    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationAuthGranted: Bool = false
    @State private var lastDeviceToken: String = ""
    @State private var isRenewingAssets: Bool = false
    @State private var renewalAlertMessage: String?
    @State private var showingRenewalAlert: Bool = false
    @State private var presentingPhotosInfoSheet: Bool = false
    @State private var logStorageInfo: DebugLogExporter.LogStorageInfo?
    @State private var showingAssistantsInfoSheet: Bool = false
    @State private var showingSafariTestSheet: Bool = false

    var body: some View {
        Group {
            Section("Features") {
                Toggle("Assistant enabled", isOn: Bindable(FeatureFlags.shared).isAssistantEnabled)

                let showInfoAction = { showingAssistantsInfoSheet = true }
                Button(action: showInfoAction) {
                    Text("Show Assistants Info Sheet")
                }
                .selfSizingSheet(isPresented: $showingAssistantsInfoSheet) {
                    AssistantsInfoView(isConfirmation: true, onConfirm: {})
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

                NavigationLink {
                    VaultKeySyncDebugView(environment: environment, session: session)
                } label: {
                    Text("Vault key sync")
                        .foregroundStyle(.colorTextPrimary)
                }
                .accessibilityIdentifier("vault-key-sync-debug-row")
            }

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

            SeedConversationsView(session: session)

            Section("Sheets") {
                Button {
                    presentingPhotosInfoSheet = true
                } label: {
                    Text("Show Photos Info Sheet")
                        .foregroundStyle(.colorTextPrimary)
                }
                NavigationLink {
                    PairingFlowDebugView()
                } label: {
                    Text("Pairing Flow Stepper")
                        .foregroundStyle(.colorTextPrimary)
                }
            }
            .selfSizingSheet(isPresented: $presentingPhotosInfoSheet) {
                PhotosInfoSheet()
            }

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
        .task {
            await refreshNotificationStatus()
            logStorageInfo = DebugLogExporter.getStorageInfo(environment: environment)
        }
        .alert("Asset Renewal", isPresented: $showingRenewalAlert, presenting: renewalAlertMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

#Preview {
    List {
        DebugViewSection(environment: .tests, session: MockInboxesService())
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

        // Use the iOS platform providers
        let platformProviders = PlatformProviders.iOS

        // Clear registration state
        DeviceRegistrationManager.clearRegistrationState(deviceInfo: platformProviders.deviceInfo)

        // Create manager with iOS platform providers for re-registration
        let manager = DeviceRegistrationManager(
            environment: ConfigManager.shared.currentEnvironment,
            platformProviders: platformProviders
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
