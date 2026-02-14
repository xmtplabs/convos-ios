import ConvosCore
import ConvosCoreiOS
import Sentry
import SwiftUI
import UIKit
import XMTPiOS

extension Client {
    static var logFileURLs: [URL]? {
        let customLogDirectory = ConfigManager.shared.currentEnvironment.defaultXMTPLogsDirectoryURL
        let filePaths = getXMTPLogFilePaths(customLogDirectory: customLogDirectory)
        guard !filePaths.isEmpty else { return nil }
        return filePaths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

struct DebugViewSection: View {
    let environment: AppEnvironment
    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationAuthGranted: Bool = false
    @State private var lastDeviceToken: String = ""
    @State private var debugFileURLs: [URL]?
    @State private var preparingLogs: Bool = false
    @State private var presentingPhotosInfoSheet: Bool = false

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    @MainActor
    private func prepareDebugInfoFile() async {
        guard !preparingLogs else { return }
        preparingLogs = true
        let logs = await ConvosLog.getLogs(appGroupIdentifier: environment.appGroupIdentifier)

        let debugInfo = """
        Convos Debug Information

        Bundle ID: \(bundleIdentifier)
        Version: \(Bundle.appVersion)
        Environment: \(ConfigManager.shared.currentEnvironment)

        \(logs)
        """

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("convos-debug-info.txt")
        try? debugInfo.write(to: tempURL, atomically: true, encoding: String.Encoding.utf8)
        var debugFileURLs = [tempURL]
        if let xmtpFileURLs = Client.logFileURLs {
            debugFileURLs.append(contentsOf: xmtpFileURLs)
        }
        self.debugFileURLs = debugFileURLs
        self.preparingLogs = false
    }

    var body: some View {
        Group {
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
                if let debugFileURLs {
                    ShareLink(items: debugFileURLs) {
                        HStack {
                            HStack {
                                Text("Share logs")
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                            }
                            .foregroundStyle(.colorTextPrimary)
                        }
                    }
                } else {
                    HStack {
                        Text("Preparing logs…")
                        Spacer()
                        if preparingLogs { ProgressView() }
                    }
                    .foregroundStyle(.colorTextSecondary)
                }

                HStack {
                    Text("Bundle ID")
                    Spacer()
                    Text(bundleIdentifier)
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

            Section("Sheets") {
                Button {
                    presentingPhotosInfoSheet = true
                } label: {
                    Text("Show Photos Info Sheet")
                        .foregroundStyle(.colorTextPrimary)
                }
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
        .selfSizingSheet(isPresented: $presentingPhotosInfoSheet) {
            PhotosInfoSheet()
        }
        .task {
            await refreshNotificationStatus()
            await prepareDebugInfoFile()
        }
    }
}

#Preview {
    List {
        DebugViewSection(environment: .tests)
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

    private func resetAllSettings() {
        ConversationViewModel.resetUserDefaults()
        ConversationsViewModel.resetUserDefaults()
        ConversationOnboardingCoordinator.resetUserDefaults()
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
