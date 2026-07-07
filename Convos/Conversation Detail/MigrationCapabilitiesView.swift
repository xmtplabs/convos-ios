import ConvosCore
import SwiftUI

/// Debug surface for the per-member migration (proposals) capabilities plus the
/// controls to enable proposals on the group. Mirrors the Android debug UI:
/// an optional min libxmtp version, "Enable proposals", and a "Force enable"
/// that bypasses the per-member capability precheck. Reloads the capabilities
/// readout after an enable so the migrated/blocking state updates in place.
struct MigrationCapabilitiesView: View {
    private let loadDebugText: () async -> String
    private let enableProposals: (_ force: Bool, _ minVersion: String?) async -> String

    @State private var debugText: String = "Loading…"
    @State private var minVersionInput: String = ""
    @State private var actionStatus: String?
    @State private var isEnabling: Bool = false

    init(
        loadDebugText: @escaping () async -> String,
        enableProposals: @escaping (_ force: Bool, _ minVersion: String?) async -> String
    ) {
        self.loadDebugText = loadDebugText
        self.enableProposals = enableProposals
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16.0) {
                controls
                Divider()
                Text(debugText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.colorTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding()
        }
        .navigationTitle("Migration capabilities")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refresh()
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8.0) {
            Text("Min libxmtp version")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.colorTextSecondary)
            TextField("optional, e.g. 1.11.0-dev", text: $minVersionInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            HStack(spacing: 12.0) {
                Button {
                    enable(force: false)
                } label: {
                    Text("Enable proposals")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isEnabling)
                Button {
                    enable(force: true)
                } label: {
                    Text("Force enable")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isEnabling)
            }
            if let actionStatus {
                Text(actionStatus)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @MainActor
    private func enable(force: Bool) {
        let trimmed = minVersionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let minVersionArg: String? = trimmed.isEmpty ? nil : trimmed
        Task {
            isEnabling = true
            actionStatus = "Enabling…"
            actionStatus = await enableProposals(force, minVersionArg)
            await refresh()
            isEnabling = false
        }
    }

    @MainActor
    private func refresh() async {
        debugText = await loadDebugText()
    }
}

#Preview {
    NavigationStack {
        MigrationCapabilitiesView(
            loadDebugText: {
                "conversationId: preview\nmigrated (proposals enabled): no\neligible to migrate now: yes"
            },
            enableProposals: { force, _ in
                "Enabled proposals\(force ? " (forced)" : "")."
            }
        )
    }
}
