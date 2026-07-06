import ConvosCore
import ConvosCoreiOS
import SwiftUI
import UserNotifications

// Module overview -- prod debug menu entry points
//
// This is the curated, read-only, own-account subset of the debug tools that
// is safe to reach in a production build. It is deliberately NOT the full
// `DebugViewSection`, which interleaves Tier-2 mutating / other-users'-data
// controls.
//
// Reachable from:
// - App Settings links group, after the version-tap gesture enables the
//   persistent toggle (see `AppSettingsView`). In production this is the only
//   debug surface.
// - Non-production builds continue to show the full `DebugViewSection`
//   unchanged via the existing environment gate; this curated view is the
//   prod-only surface.
//
// Hard rules enforced here:
// - No mutating controls (no "Request Now", no "Register Device Again", no
//   purchase / change-plan CTAs, no mock-credit toggles).
// - The live `BackendAuthProbe` (JWT minter) is never imported or instantiated
//   here. The identity readout uses `DeviceIdentitySnapshot`, which is
//   network-free and carries no JWT.
// - Sensitive correlators (eth address, accountId, inboxId, installation ids,
//   APNs token) are masked by default with explicit tap-to-reveal + copy.
struct ProdDebugMenuView: View {
    let environment: AppEnvironment
    let session: any SessionManagerProtocol

    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationAuthGranted: Bool = false
    @State private var apnsToken: String = ""
    @State private var logStorageInfo: DebugLogExporter.LogStorageInfo?
    @State private var exportedLogsURL: URL?
    @State private var isExportingLogs: Bool = false
    @State private var identity: DeviceIdentitySnapshot?
    @State private var installations: InstallationsSnapshot?
    @State private var debugModeEnabled: Bool = DebugMenuFlagStore.isEnabled()
    @State private var creditBalance: CreditBalance? = CreditsServices.shared.currentBalance
    @State private var currentSubscription: UserSubscription? = SubscriptionServices.shared.currentSubscription

    var body: some View {
        List {
            debugModeSection
            buildSection
            identitySection
            subscriptionSection
            pushSection
            featureFlagsSection
            logsSection
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .navigationTitle("Debug menu")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(CreditsServices.shared.balancePublisher) { creditBalance = $0 }
        .onReceive(SubscriptionServices.shared.subscriptionPublisher) { currentSubscription = $0 }
        .task {
            await loadDiagnostics()
        }
    }

    // MARK: - Debug mode toggle

    @ViewBuilder
    private var debugModeSection: some View {
        Section {
            Toggle("Debug mode", isOn: $debugModeEnabled)
                .onChange(of: debugModeEnabled) { _, newValue in
                    DebugMenuFlagStore.setEnabled(newValue)
                }
        } footer: {
            Text("Turn this off to hide the debug menu and clear the on-screen indicator.")
        }
    }

    // MARK: - Build / environment

    @ViewBuilder
    private var buildSection: some View {
        let bundleId: String = Bundle.main.bundleIdentifier ?? "Unknown"
        let buildNumber: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let environmentName: String = environment.name.capitalized
        Section("Build") {
            labeledRow("Version", Bundle.appVersion)
            labeledRow("Build", buildNumber)
            labeledRow("Bundle ID", bundleId)
            labeledRow("Environment", environmentName)
        }
    }

    // MARK: - Identity (Tier 1, network-free, no JWT)

    @ViewBuilder
    private var identitySection: some View {
        let siwe: SIWEConfiguration = environment.siweConfiguration
        Section("Identity") {
            DebugRevealableValueRow(label: "ETH address", value: identity?.ethAddress)
            DebugRevealableValueRow(label: "Account ID", value: identity?.accountId)
            DebugRevealableValueRow(label: "Inbox ID", value: identity?.inboxId ?? installations?.inboxId)
            DebugRevealableValueRow(label: "Installation ID", value: installations?.currentInstallationId)
            peerInstallationsRows
            labeledRow("SIWE domain", siwe.domain)
            labeledRow("SIWE URI", siwe.uri)
            labeledRow("SIWE chain ID", "\(siwe.chainId)")
        }
    }

    @ViewBuilder
    private var peerInstallationsRows: some View {
        let currentId: String? = installations?.currentInstallationId
        let peers: [InstallationInfo] = installations?.installations.filter { $0.id != currentId } ?? []
        ForEach(peers, id: \.id) { (peer: InstallationInfo) in
            DebugRevealableValueRow(label: "Peer installation", value: peer.id)
        }
    }

    // MARK: - Subscription & credits (Tier 1, read-only)

    @ViewBuilder
    private var subscriptionSection: some View {
        Section("Subscription & Credits") {
            labeledRow("Plan", subscriptionPlanText)
            labeledRow("Status", subscriptionStatusText)
            if let subscription = currentSubscription {
                labeledRow("Product ID", subscription.productId)
                labeledRow("Period", subscription.period == .monthly ? "Monthly" : "Annual")
                labeledRow("Renews", subscription.willRenew ? "Yes" : "No")
                labeledRow("In trial", subscription.isInTrial ? "Yes" : "No")
                labeledRow("Period end", Self.dateText(subscription.currentPeriodEnd))
            }
            creditRows
        }
    }

    @ViewBuilder
    private var creditRows: some View {
        if let balance = creditBalance {
            labeledRow("Credits", "\(balance.balance) / \(balance.monthlyGrant)")
            labeledRow("Grant used", "\(balance.monthlyGrantUsed)")
            labeledRow("Period", balance.periodLabel)
            labeledRow("Next refresh", Self.dateText(balance.nextRefreshAt))
        } else {
            labeledRow("Credits", "(unavailable)")
        }
    }

    // MARK: - Push diagnostics (Tier 1, masked token, no mutating buttons)

    @ViewBuilder
    private var pushSection: some View {
        let apnsEnv: String = environment.apnsEnvironment.rawValue
        Section("Push") {
            labeledRow("Auth status", Self.authStatusText(notificationAuthStatus))
            labeledRow("Authorized", notificationAuthGranted ? "Yes" : "No")
            labeledRow("APNs environment", apnsEnv)
            DebugRevealableValueRow(label: "APNs token", value: apnsToken.isEmpty ? nil : apnsToken)
        }
    }

    // MARK: - Feature flags (display only)

    @ViewBuilder
    private var featureFlagsSection: some View {
        let injectorEnabled: Bool = FeatureFlags.shared.isDebugInjectorEnabled
        Section("Feature flags") {
            labeledRow("Debug injector", injectorEnabled ? "On" : "Off")
        }
    }

    // MARK: - Logs (read-only export, already ships in prod)

    @ViewBuilder
    private var logsSection: some View {
        Section("Logs") {
            HStack {
                Text("Log storage")
                    .foregroundStyle(.colorTextPrimary)
                Spacer()
                if let info = logStorageInfo {
                    Text(info.formattedTotalSize)
                        .foregroundStyle(.colorTextSecondary)
                } else {
                    ProgressView()
                }
            }
            logExportRow
        }
    }

    @ViewBuilder
    private var logExportRow: some View {
        if let url = exportedLogsURL {
            ShareLink(item: url) {
                HStack {
                    Text("Share logs")
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.colorTextSecondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            let exportAction: () -> Void = {
                Task { await prepareExportedLogs() }
            }
            Button(action: exportAction) {
                HStack {
                    Text("Export logs")
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    if isExportingLogs { ProgressView() }
                }
            }
            .disabled(isExportingLogs)
        }
    }

    // MARK: - Shared rows

    @ViewBuilder
    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.colorTextPrimary)
            Spacer()
            Text(value)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    // MARK: - Derived text

    private var subscriptionPlanText: String {
        guard let subscription = currentSubscription else { return "Free" }
        let name: String = SubscriptionCopy.displayName(for: subscription.tier)
        return subscription.isInTrial ? "\(name) trial" : name
    }

    private var subscriptionStatusText: String {
        guard let subscription = currentSubscription else { return "No subscription" }
        switch subscription.status {
        case .trial: return "Trial"
        case .active: return "Active"
        case .grace: return "Grace"
        case .billingRetry: return "Billing retry"
        case .expired: return "Expired"
        case .revoked: return "Revoked"
        }
    }

    // MARK: - Loading

    private func loadDiagnostics() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthStatus = settings.authorizationStatus
        notificationAuthGranted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        apnsToken = PushNotificationRegistrar.token ?? ""
        logStorageInfo = DebugLogExporter.getStorageInfo(environment: environment)

        let store = KeychainIdentityStore(accessGroup: environment.keychainAccessGroup)
        identity = await DeviceIdentitySnapshot.current(identityStore: store)

        do {
            installations = try await session.messagingService().installationsSnapshot(refreshFromNetwork: false)
        } catch {
            Log.warning("ProdDebugMenuView: failed to read installations: \(error)")
        }
    }

    private func prepareExportedLogs() async {
        guard !isExportingLogs else { return }
        isExportingLogs = true
        defer { isExportingLogs = false }
        let environment = environment
        let url = await Task.detached { () -> URL? in
            do {
                return try DebugLogExporter.exportAllLogs(environment: environment)
            } catch {
                Log.error("ProdDebugMenuView: failed to export logs: \(error.localizedDescription)")
                return nil
            }
        }.value
        exportedLogsURL = url
    }

    private static func authStatusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    NavigationStack {
        ProdDebugMenuView(environment: .tests, session: MockInboxesService())
    }
}
