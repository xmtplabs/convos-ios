import ConvosCore
import ConvosCoreiOS
import CryptoKit
import SwiftUI
import UIKit
import UserNotifications

/// Stack 2 T17: read-only debug screen that surfaces the iOS-side push
/// registration state alongside backend's view via the new
/// `POST /v2/notifications/debug/status` endpoint.
///
/// Production-safe: the backend response is hashes-only by contract, and
/// nothing here writes any state. The "Copy Diagnostics" button produces a
/// redacted snapshot (token shown as SHA-256 prefix only) safe to paste
/// into a Slack thread.
///
/// `Force Reconcile` is intentionally not wired here yet: it needs a
/// SessionManagerProtocol method that exposes the SyncingManager's
/// `clearPushSubscriptionCache` + `requestDiscovery` pair. Tracked as a
/// follow-up so this screen can ship and start providing visibility today.
struct DebugPushNotificationsView: View {
    let environment: AppEnvironment
    let session: any SessionManagerProtocol

    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var localIdentity: ResolvedLocalIdentity?
    @State private var backendStatus: ConvosAPI.DebugStatusResponse?
    @State private var probeError: String?
    @State private var isProbing: Bool = false
    @State private var isForcingReconcile: Bool = false
    @State private var forceReconcileResult: String?

    var body: some View {
        List {
            localStateSection
            backendStateSection
            actionsSection
            footerSection
        }
        .navigationTitle("Push Notifications Debug")
        .task {
            await refreshLocalState()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var localStateSection: some View {
        Section(header: Text("Local (this device)")) {
            row("Registrar configured", value: PushNotificationRegistrar.token != nil ? "yes" : "no (token nil)")
            row("Auth status", value: statusText(notificationAuthStatus))
            row("Environment", value: environment.name)
            row("APNS env", value: environment.apnsEnvironment.rawValue)
            row("Bundle id", value: Bundle.main.bundleIdentifier ?? "unknown")
            row("Device id", value: ConvosCore.DeviceInfo.deviceIdentifier)
            row("Inbox id", value: localIdentity?.inboxId ?? "—")
            row("Client id", value: localIdentity?.clientId ?? "—")
            row("Account id", value: localIdentity?.accountId ?? "—")
            row("APNS token (sha-8)", value: tokenSha8(PushNotificationRegistrar.token))
        }
    }

    @ViewBuilder
    private var backendStateSection: some View {
        Section(header: Text("Backend (after Probe)")) {
            if let err = probeError {
                row("Probe error", value: err, color: .red)
            } else if let backendStatus = backendStatus {
                row("Device row exists", value: yn(backendStatus.device.exists))
                row("Backend has push token", value: yn(backendStatus.device.hasPushToken))
                row("Push token matches", value: ynOptional(backendStatus.device.pushTokenMatches))
                row("APNS env matches", value: ynOptional(backendStatus.device.apnsEnvMatches))
                row("Device disabled", value: ynOptional(backendStatus.device.disabled))
                row("Push failures", value: backendStatus.device.pushFailures.map(String.init) ?? "—")
                row("Last sent", value: backendStatus.device.lastSentAt ?? "—")
                row("Last failure", value: backendStatus.device.lastFailureAt ?? "—")
                Divider()
                row("Client row exists", value: yn(backendStatus.client.exists))
                row("Client.deviceId matches JWT", value: ynOptional(backendStatus.client.deviceIdMatchesJwt))
                row("Client.accountId matches JWT", value: ynOptional(backendStatus.client.accountIdMatchesJwt))
                Divider()
                row("Snapshot exists", value: yn(backendStatus.subscriptionSnapshot.exists))
                row("Snapshot topic count", value: backendStatus.subscriptionSnapshot.topicCount.map(String.init) ?? "—")
                row("Snapshot topic hash (8)", value: trim8(backendStatus.subscriptionSnapshot.topicHash))
                row("Snapshot context", value: backendStatus.subscriptionSnapshot.lastContext ?? "—")
                row("Snapshot last applied", value: backendStatus.subscriptionSnapshot.lastSubscribeAt ?? "—")
                row("Snapshot last remote ok", value: ynOptional(backendStatus.subscriptionSnapshot.lastRemoteApplySucceeded))
                row("Snapshot token matches at-apply", value: ynOptional(backendStatus.subscriptionSnapshot.pushTokenMatchesAtApply))
                row("Snapshot apnsEnv matches at-apply", value: ynOptional(backendStatus.subscriptionSnapshot.apnsEnvMatchesAtApply))
            } else {
                Text("Tap Probe to query backend.")
                    .foregroundStyle(.secondary)
            }
            Text("Note: backend reports LAST REQUESTED topic state, not actual XMTP remote state.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section(header: Text("Actions")) {
            // `_ =` discards the Task return value so the closure infers as
            // `() -> Void` (matching Button's expected action shape) instead
            // of `() -> Task<(), Never>`.
            let probeAction = { _ = Task { await runProbe() } }
            Button(action: probeAction) {
                HStack {
                    Text("Probe backend")
                    Spacer()
                    if isProbing { ProgressView() }
                }
            }
            .disabled(isProbing || localIdentity == nil)

            let copyAction = { copyDiagnostics() }
            Button(action: copyAction) {
                Text("Copy diagnostics JSON (redacted)")
            }
            .disabled(localIdentity == nil)

            // `_ =` discards the Task return value so the closure infers as
            // `() -> Void` (matching Button's expected action shape).
            let forceAction = { _ = Task { await runForceReconcile() } }
            Button(action: forceAction) {
                HStack {
                    Text("Force topic reconcile")
                    Spacer()
                    if isForcingReconcile { ProgressView() }
                }
            }
            .disabled(isForcingReconcile)
            if let forceReconcileResult = forceReconcileResult {
                Text(forceReconcileResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var footerSection: some View {
        Section {
            Text(
                "Force topic reconcile clears the iOS cache and fires a fresh subscribe " +
                "through to the backend, bypassing the discoverNewConversations count-gate. " +
                "Use it when you've changed backend state out-of-band (deleted snapshot, " +
                "rotated key, etc.) and want to re-prime."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func row(_ label: String, value: String, color: Color = .colorTextSecondary) -> some View {
        HStack(alignment: .top) {
            Text(label)
            Spacer()
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

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

    private func yn(_ value: Bool) -> String { value ? "yes" : "no" }
    private func ynOptional(_ value: Bool?) -> String { value.map(yn) ?? "—" }
    private func trim8(_ value: String?) -> String {
        guard let value = value, value.count >= 8 else { return value ?? "—" }
        return String(value.prefix(8))
    }
    private func tokenSha8(_ token: String?) -> String {
        guard let token = token, !token.isEmpty else { return "none" }
        let digest = SHA256.hash(data: Data(token.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }
    private func fullTokenSha(_ token: String?) -> String {
        guard let token = token, !token.isEmpty else { return "none" }
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Actions

    private func refreshLocalState() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            notificationAuthStatus = settings.authorizationStatus
        }

        let store = KeychainIdentityStore(accessGroup: environment.keychainAccessGroup)
        let identity = (try? await store.load())
        let status = await BackendAuthProbe.currentStatus(environment: environment, identityStore: store)
        await MainActor.run {
            localIdentity = ResolvedLocalIdentity(
                inboxId: identity?.inboxId,
                clientId: identity?.clientId,
                accountId: status.accountId
            )
        }
    }

    private func runProbe() async {
        guard let localIdentity = localIdentity,
              let clientId = localIdentity.clientId else {
            probeError = "No client id available; sign in first."
            return
        }
        await MainActor.run {
            isProbing = true
            probeError = nil
        }
        defer {
            Task { @MainActor in isProbing = false }
        }

        do {
            let apiClient = ConvosAPIClientFactory.client(environment: environment)
            let response = try await apiClient.debugStatus(
                deviceId: ConvosCore.DeviceInfo.deviceIdentifier,
                clientId: clientId,
                pushTokenSha256: fullTokenSha(PushNotificationRegistrar.token),
                pushTokenType: "apns",
                apnsEnv: environment.apnsEnvironment.rawValue
            )
            await MainActor.run {
                backendStatus = response
            }
        } catch {
            await MainActor.run {
                probeError = String(describing: error)
            }
        }
    }

    private func runForceReconcile() async {
        await MainActor.run {
            isForcingReconcile = true
            forceReconcileResult = nil
        }
        defer {
            Task { @MainActor in isForcingReconcile = false }
        }
        let messagingService = session.messagingService()
        await messagingService.sessionStateManager.forceReconcilePushTopics()
        await MainActor.run {
            forceReconcileResult = "Forced reconcile dispatched — re-probe to see updated snapshot."
        }
    }

    private func copyDiagnostics() {
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "environment": environment.name,
            "deviceId": ConvosCore.DeviceInfo.deviceIdentifier,
            "inboxId": localIdentity?.inboxId ?? NSNull(),
            "clientId": localIdentity?.clientId ?? NSNull(),
            "accountId": localIdentity?.accountId ?? NSNull(),
            "apnsEnv": environment.apnsEnvironment.rawValue,
            "registrarConfigured": PushNotificationRegistrar.token != nil,
            "pushTokenSha256": fullTokenSha(PushNotificationRegistrar.token),
            "notificationAuthStatus": statusText(notificationAuthStatus),
            "backend": backendStatus.map { dictFromBackend($0) } ?? NSNull(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            UIPasteboard.general.string = text
        }
    }

    private func dictFromBackend(_ response: ConvosAPI.DebugStatusResponse) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(response),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["error": "encoding failed"]
        }
        return dict
    }
}

private struct ResolvedLocalIdentity {
    let inboxId: String?
    let clientId: String?
    let accountId: String?
}
