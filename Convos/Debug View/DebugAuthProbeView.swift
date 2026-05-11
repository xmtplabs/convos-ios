import ConvosCore
import SwiftUI

/// Debug-only end-to-end SIWE probe. Hits the local backend, fetches a
/// nonce, signs an EIP-4361 message with the on-device XMTP identity,
/// exchanges it for a SIWE-bound JWT, and calls `/v2/account-auth-check`.
/// Renders progress + final result inline.
struct DebugAuthProbeView: View {
    let environment: AppEnvironment

    @State private var isRunning: Bool = false
    @State private var log: [LogLine] = []
    @State private var probeResult: BackendAuthProbe.Result?
    @State private var negativeProbePassed: Bool?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                actionsSection
                resultSection
                logSection(proxy: proxy)
            }
        }
        .navigationTitle("SIWE Auth Probe")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section("Actions") {
            let runAction: () -> Void = { Task { await runProbe() } }
            Button(action: runAction) {
                HStack {
                    Text("Run Auth Probe")
                    Spacer()
                    if isRunning { ProgressView() }
                }
            }
            .disabled(isRunning)

            let negativeAction: () -> Void = { Task { await runNegativeProbe() } }
            Button(action: negativeAction) {
                Text("Probe /account-auth-check without auth")
            }
            .disabled(isRunning)

            let clearAction: () -> Void = {
                log = []
                probeResult = nil
                negativeProbePassed = nil
            }
            Button(action: clearAction) {
                Text("Clear Log")
                    .foregroundStyle(.secondary)
            }
            .disabled(isRunning || log.isEmpty)
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let probeResult {
            Section("Last Result") {
                resultRow("Address", probeResult.address, monospaced: true)
                resultRow("AccountId", probeResult.accountId ?? "(none)", monospaced: probeResult.accountId != nil)
                resultRow("JWT exp", probeResult.jwtExpiry.map { iso8601($0) } ?? "(unknown)")
                resultRow(
                    "/account-auth-check",
                    probeResult.accountAuthCheckPassed ? "200 OK" : "FAILED",
                    color: probeResult.accountAuthCheckPassed ? .green : .red
                )
            }
        }
        if let negativeProbePassed {
            Section("Negative Probe") {
                resultRow(
                    "no-auth → 401",
                    negativeProbePassed ? "PASSED" : "FAILED",
                    color: negativeProbePassed ? .green : .red
                )
            }
        }
    }

    @ViewBuilder
    private func logSection(proxy: ScrollViewProxy) -> some View {
        if !log.isEmpty {
            Section("Log") {
                ForEach(log) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: line.icon)
                            .foregroundStyle(line.color)
                            .font(.caption)
                        Text(line.text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .id(line.id)
                }
            }
            .onChange(of: log.count) { _, _ in
                if let last = log.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ label: String, _ value: String, monospaced: Bool = false, color: Color = .primary) -> some View {
        HStack(alignment: .top) {
            Text(label)
            Spacer()
            Group {
                if monospaced {
                    Text(value).font(.system(.footnote, design: .monospaced))
                } else {
                    Text(value)
                }
            }
            .foregroundStyle(color)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
        }
    }

    // MARK: - Probe execution

    private func runProbe() async {
        isRunning = true
        defer { isRunning = false }

        probeResult = nil
        appendLog("Starting SIWE probe…", .info)

        let store = KeychainIdentityStore(accessGroup: environment.keychainAccessGroup)
        do {
            let result = try await BackendAuthProbe.run(
                environment: environment,
                identityStore: store,
                progress: { line in
                    Task { @MainActor in
                        self.appendLog(line, .info)
                    }
                }
            )
            probeResult = result
            if result.accountAuthCheckPassed {
                appendLog("/account-auth-check → 200 OK", .success)
            } else {
                appendLog("/account-auth-check did not return 200 (see log)", .failure)
            }
        } catch {
            appendLog("Probe failed: \(error)", .failure)
        }
    }

    private func runNegativeProbe() async {
        isRunning = true
        defer { isRunning = false }

        negativeProbePassed = nil
        appendLog("Calling /account-auth-check with no auth header…", .info)
        let passed = await BackendAuthProbe.probeWithoutAuth(environment: environment)
        negativeProbePassed = passed
        appendLog(
            passed
                ? "Got rejected as expected (401/403)."
                : "Did not get the expected 401/403 — gating may be broken.",
            passed ? .success : .failure
        )
    }

    private func appendLog(_ text: String, _ kind: LogLine.Kind) {
        log.append(LogLine(text: text, kind: kind))
    }

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private struct LogLine: Identifiable {
        let id: UUID = UUID()
        let text: String
        let kind: Kind

        enum Kind { case info, success, failure }

        var icon: String {
            switch kind {
            case .info: return "arrow.right.circle"
            case .success: return "checkmark.circle.fill"
            case .failure: return "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch kind {
            case .info: return .secondary
            case .success: return .green
            case .failure: return .red
            }
        }
    }
}

#Preview {
    NavigationStack {
        DebugAuthProbeView(environment: .tests)
    }
}
