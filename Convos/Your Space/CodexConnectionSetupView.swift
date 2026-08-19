import SwiftUI
import UIKit

struct CodexConnectionSetupView: View {
    let onConnected: () -> Void

    @State private var endpoint: String
    @State private var capabilityToken: String
    @State private var workspacePath: String
    @State private var sharesYourSpaceContext: Bool
    @State private var allowsNetworkAccess: Bool
    @State private var showsAdvancedSetup: Bool = false
    @State private var isConnecting: Bool = false
    @State private var connectionSummary: CodexConnectionSummary?
    @State private var connectionError: String?

    init(onConnected: @escaping () -> Void) {
        self.onConnected = onConnected
        let existing = CodexConnectionStore.configuration()
        _endpoint = State(initialValue: existing?.endpoint.absoluteString ?? "ws://your-mac.local:4500")
        _capabilityToken = State(initialValue: existing?.capabilityToken ?? "")
        _workspacePath = State(initialValue: existing?.workspacePath ?? "")
        _sharesYourSpaceContext = State(initialValue: existing?.sharesYourSpaceContext ?? true)
        _allowsNetworkAccess = State(initialValue: existing?.allowsNetworkAccess ?? true)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                introduction
                pairingSetup
                contextBoundary
                advancedSetup
                connectionStatus
            }
            .padding(.horizontal, DesignConstants.Spacing.step5x)
            .padding(.top, DesignConstants.Spacing.step5x)
            .padding(.bottom, 130)
        }
        .background(.colorBackgroundSurfaceless)
        .navigationTitle("Connect Codex")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: ExternalAgentProvider.codex.symbolName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 68, height: 68)
                .background(ExternalAgentProvider.codex.tint, in: .circle)

            Text("Talk to the Codex on your Mac")
                .font(.largeTitle.bold())
                .tracking(-0.8)
                .foregroundStyle(.colorTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Pair once, then ask Codex to build from the context in Your Space. Codex keeps running on your Mac; anything it returns stays private until you save it or share it to a convo.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pairingSetup: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Label("Pair from your Mac", systemImage: "desktopcomputer")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)

            Text("In this repo on your Mac, run one command. It starts Codex, approves this workspace, and copies a private pairing link through Universal Clipboard.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            command("./Scripts/connect-codex-to-convos")

            Button {
                pairFromMac()
            } label: {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    if isConnecting {
                        ProgressView()
                            .tint(.colorTextPrimaryInverted)
                    } else {
                        Image(systemName: "link.badge.plus")
                    }
                    Text(isConnecting ? "Finding Codex on your Mac…" : "Pair from Mac")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.colorTextPrimaryInverted)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(.colorFillPrimary, in: .rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)
            .accessibilityIdentifier("codex-pair-from-mac-button")

            Text("Keep that terminal window open while you use Codex. Pair only on a private network you trust.")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
    }

    private var advancedSetup: some View {
        DisclosureGroup("Advanced manual setup", isExpanded: $showsAdvancedSetup) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                Text("If Universal Clipboard is unavailable, start Codex directly and enter the Mac address, token, and workspace below.")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                command("codex app-server --listen ws://0.0.0.0:4500 --ws-auth capability-token --ws-token-file ~/.codex/convos-token")
                connectionFields
                connectButton
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .font(.headline)
        .foregroundStyle(.colorTextPrimary)
    }

    private func command(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.colorTextPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignConstants.Spacing.step3x)
            .background(.colorFillMinimal, in: .rect(cornerRadius: 10))
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Mac connection")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)

            fieldLabel("WebSocket address")
            TextField("ws://your-mac.local:4500", text: $endpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .padding(DesignConstants.Spacing.step3x)
                .background(.colorFillMinimal, in: .rect(cornerRadius: 12))
                .accessibilityIdentifier("codex-connection-endpoint")

            fieldLabel("Capability token")
            SecureField("Paste from ~/.codex/convos-token", text: $capabilityToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .padding(DesignConstants.Spacing.step3x)
                .background(.colorFillMinimal, in: .rect(cornerRadius: 12))
                .accessibilityIdentifier("codex-connection-token")

            fieldLabel("Approved workspace on the Mac")
            TextField("/Users/you/project (optional)", text: $workspacePath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(DesignConstants.Spacing.step3x)
                .background(.colorFillMinimal, in: .rect(cornerRadius: 12))
                .accessibilityIdentifier("codex-connection-workspace")

            Text("When a workspace is set, Codex can read it and make changes inside it without remote approval prompts. Commands that need broader access are denied by this iPhone connection.")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.colorTextSecondary)
    }

    private var contextBoundary: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Toggle(isOn: $sharesYourSpaceContext) {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text("Use Your Space context")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Text("Each request includes your current briefing, remembered details, useful message details, links, and text from local notes. Photos and other files send metadata only.")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("codex-share-your-space-context")

            Divider()

            Toggle(isOn: $allowsNetworkAccess) {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text("Let Codex use the internet")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Text("Lets Codex research, use connected tools, and publish a result when your Mac setup supports it. File changes stay inside the approved workspace.")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("codex-allow-network-access")
        }
        .tint(.colorLava)
        .padding(DesignConstants.Spacing.step4x)
        .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if let connectionSummary {
            Label {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text("Connected to Codex")
                        .font(.body.weight(.semibold))
                    Text(summaryText(connectionSummary))
                        .font(.footnote)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.colorTextPrimary)
            .padding(DesignConstants.Spacing.step4x)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.12), in: .rect(cornerRadius: 16))
        }

        if let connectionError {
            Label(connectionError, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(DesignConstants.Spacing.step4x)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 16))
        }
    }

    private var connectButton: some View {
        Button {
            connect()
        } label: {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                if isConnecting {
                    ProgressView()
                        .tint(.colorTextPrimaryInverted)
                }
                Text(isConnecting ? "Connecting to your Mac…" : "Connect Codex")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.colorTextPrimaryInverted)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(.colorFillPrimary, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
        .padding(.horizontal, DesignConstants.Spacing.step5x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .background(.colorBackgroundSurfaceless)
        .accessibilityIdentifier("codex-connect-button")
    }

    private func connect() {
        guard !isConnecting else { return }
        connectionError = nil
        connectionSummary = nil

        let configuration: CodexConnectionConfiguration
        do {
            configuration = try CodexConnectionConfiguration(
                endpointText: endpoint,
                capabilityToken: capabilityToken,
                workspacePath: workspacePath,
                sharesYourSpaceContext: sharesYourSpaceContext,
                allowsNetworkAccess: allowsNetworkAccess
            )
        } catch {
            connectionError = error.localizedDescription
            return
        }

        connect(configuration)
    }

    private func pairFromMac() {
        guard !isConnecting else { return }
        connectionError = nil
        connectionSummary = nil
        guard let value = UIPasteboard.general.string else {
            connectionError = "No pairing link was found. Run the pairing command on your Mac, wait for “Ready for Convos,” then try again."
            return
        }

        do {
            let pairingLink = try CodexPairingLink(value)
            endpoint = pairingLink.endpoint.absoluteString
            capabilityToken = pairingLink.capabilityToken
            workspacePath = pairingLink.workspacePath ?? ""
            let configuration = try pairingLink.configuration(
                sharesYourSpaceContext: sharesYourSpaceContext,
                allowsNetworkAccess: allowsNetworkAccess
            )
            connect(configuration)
        } catch {
            connectionError = error.localizedDescription
        }
    }

    private func connect(_ configuration: CodexConnectionConfiguration) {
        isConnecting = true
        Task { @MainActor in
            do {
                let summary = try await CodexAppServerClient().probe(configuration)
                try CodexConnectionStore.save(configuration)
                connectionSummary = summary
                isConnecting = false
                try? await Task.sleep(for: .milliseconds(500))
                onConnected()
            } catch {
                isConnecting = false
                connectionError = connectionErrorDescription(error)
            }
        }
    }

    private func connectionErrorDescription(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost:
                return "Convos couldn’t reach Codex. Keep the Mac command running, confirm both devices are on the same network, and check the Mac name or IP address."
            case .userAuthenticationRequired:
                return "Codex rejected the capability token. Paste the exact value from your Mac token file."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private func summaryText(_ summary: CodexConnectionSummary) -> String {
        var parts: [String] = []
        let suffix = summary.hasMoreThreads ? "+" : ""
        parts.append("\(summary.visibleThreadCount)\(suffix) recent Codex tasks available")
        if let latestThreadName = summary.latestThreadName, !latestThreadName.isEmpty {
            parts.append("Latest: \(latestThreadName)")
        } else if let latestWorkspacePath = summary.latestWorkspacePath {
            parts.append(latestWorkspacePath)
        }
        return parts.joined(separator: " · ")
    }
}
