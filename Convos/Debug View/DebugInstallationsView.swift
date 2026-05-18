import ConvosCore
import SwiftUI

/// Debug-only inspector for the device's XMTP installations. Lists every
/// installation the network reports for this inbox (current one marked) and
/// offers a single action: revoke every other installation. Used to recover
/// from the 10-installation cap that accumulates across wipe + reinstall
/// cycles during development.
struct DebugInstallationsView: View {
    @State private var snapshot: InstallationsSnapshot?
    @State private var isLoading: Bool = false
    @State private var isRevoking: Bool = false
    @State private var lastRevoked: [String] = []
    @State private var errorMessage: String?

    let messagingService: AnyMessagingService

    var body: some View {
        List {
            if let snapshot {
                summarySection(snapshot)
                installationsSection(snapshot)
                actionsSection(snapshot)
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text(isLoading ? "Loading installations…" : "Tap refresh to load.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if !lastRevoked.isEmpty {
                Section("Revoked this session") {
                    ForEach(lastRevoked, id: \.self) { id in
                        Text(id)
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .navigationTitle("XMTP Installations")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    @ViewBuilder
    private func summarySection(_ snapshot: InstallationsSnapshot) -> some View {
        let total = snapshot.installations.count
        let cap = 10
        let countColor: Color = total >= cap ? .red : (total >= cap - 2 ? .orange : .primary)
        Section("Summary") {
            row("Inbox ID", snapshot.inboxId)
            row("This device", snapshot.currentInstallationId)
            HStack {
                Text("Installations")
                Spacer()
                Text("\(total) / \(cap)")
                    .foregroundStyle(countColor)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func installationsSection(_ snapshot: InstallationsSnapshot) -> some View {
        Section("Installations") {
            ForEach(snapshot.installations, id: \.id) { installation in
                installationRow(installation, currentId: snapshot.currentInstallationId)
            }
        }
    }

    @ViewBuilder
    private func installationRow(_ installation: InstallationInfo, currentId: String) -> some View {
        let isCurrent = installation.id == currentId
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(installation.id)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isCurrent {
                    Text("CURRENT")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }
            }
            if let createdAt = installation.createdAt {
                Text(createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ snapshot: InstallationsSnapshot) -> some View {
        let otherCount = snapshot.installations.count - 1
        let refreshAction: () -> Void = { Task { await refresh() } }
        let revokeAction: () -> Void = { Task { await revokeOthers() } }

        Section("Actions") {
            Button(action: refreshAction) {
                Label("Refresh from network", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading || isRevoking)

            Button(role: .destructive, action: revokeAction) {
                if isRevoking {
                    HStack {
                        ProgressView()
                        Text("Revoking…")
                    }
                } else if otherCount > 0 {
                    Text("Revoke all other installations (\(otherCount))")
                } else {
                    Text("No other installations to revoke")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(otherCount == 0 || isLoading || isRevoking)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            snapshot = try await messagingService.installationsSnapshot(refreshFromNetwork: true)
        } catch {
            errorMessage = "Failed to load installations: \(error.localizedDescription)"
        }
    }

    private func revokeOthers() async {
        guard !isRevoking else { return }
        isRevoking = true
        errorMessage = nil
        defer { isRevoking = false }
        do {
            let revoked = try await messagingService.revokeOtherInstallations()
            lastRevoked = revoked
            snapshot = try await messagingService.installationsSnapshot(refreshFromNetwork: true)
        } catch {
            errorMessage = "Revoke failed: \(error.localizedDescription)"
        }
    }
}
