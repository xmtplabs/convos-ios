import ConvosCore
import SwiftUI

struct BackupRestoreSettingsView: View {
    @Bindable var viewModel: BackupRestoreViewModel
    let onRestore: (AvailableBackup) -> Void

    @State private var showingRestoreConfirmation: Bool = false
    @State private var pendingRestore: AvailableBackup?

    var body: some View {
        List {
            backUpSection()
            if let available = viewModel.availableRestore {
                restoreSection(available: available)
            }
            if let failure = viewModel.pendingArchiveImportFailure {
                partialRestoreSection(failure: failure)
            }
            statusSection()
        }
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.refresh() }
        .confirmationDialog(
            "Restore from backup?",
            isPresented: $showingRestoreConfirmation,
            titleVisibility: .visible
        ) {
            let confirm = {
                if let available = pendingRestore {
                    onRestore(available)
                }
                pendingRestore = nil
            }
            Button("Restore", role: .destructive, action: confirm)
            Button("Cancel", role: .cancel) {
                pendingRestore = nil
            }
        } message: {
            if let sidecar = pendingRestore?.sidecar {
                Text(
                    "Replace this device's data with the backup from "
                    + "\(sidecar.deviceName) "
                    + "(\(sidecar.createdAt.formatted(date: .abbreviated, time: .shortened)))? "
                    + "You can't undo this."
                )
            } else {
                Text("This will replace the data on this device with the backup. You can't undo this.")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func backUpSection() -> some View {
        Section {
            if viewModel.isBackupInProgress {
                HStack {
                    Text("Backing up…")
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    ProgressView()
                }
            } else {
                let backUp: @MainActor () -> Void = {
                    Task { await viewModel.backUpNow() }
                }
                Button(action: backUp) {
                    HStack {
                        Text("Back up now")
                            .foregroundStyle(.colorTextPrimary)
                        Spacer()
                        Image(systemName: "icloud.and.arrow.up")
                            .foregroundStyle(.colorTextSecondary)
                    }
                }
                .accessibilityIdentifier("back-up-now-button")
            }
        } header: {
            Text("Backup")
        } footer: {
            if let error = viewModel.lastError {
                Text("Backup failed: \(error.localizedDescription)")
                    .foregroundStyle(.colorLava)
            } else if let date = viewModel.lastBackupAt {
                Text("Last backup: \(date.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("No backup yet — Convos backs up your conversations daily.")
            }
        }
    }

    @ViewBuilder
    private func restoreSection(available: AvailableBackup) -> some View {
        Section {
            let restore = {
                pendingRestore = available
                showingRestoreConfirmation = true
            }
            Button(action: restore) {
                HStack {
                    Text("Restore from backup")
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundStyle(.colorTextSecondary)
                }
            }
            .accessibilityIdentifier("restore-from-backup-button")
        } header: {
            Text("Restore")
        } footer: {
            Text(
                "From \(available.sidecar.deviceName) · "
                + "\(available.sidecar.createdAt.formatted(date: .abbreviated, time: .shortened)) · "
                + "\(available.sidecar.conversationCount) convo\(available.sidecar.conversationCount == 1 ? "" : "s")"
            )
        }
    }

    @ViewBuilder
    private func partialRestoreSection(failure: PendingArchiveImportFailure) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.colorLava)
                    Text("Message history wasn't fully restored")
                        .foregroundStyle(.colorLava)
                }
                Text(failure.reason)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                Text("Run restore again from the same backup to retry.")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            let dismiss = { viewModel.dismissPartialRestoreWarning() }
            Button("Dismiss warning", action: dismiss)
                .accessibilityIdentifier("dismiss-partial-restore-warning")
        } header: {
            Text("Partial restore")
        }
    }

    @ViewBuilder
    private func statusSection() -> some View {
        Section {
            HStack {
                Text("iCloud")
                    .foregroundStyle(.colorTextPrimary)
                Spacer()
                if viewModel.iCloudAvailable {
                    Label("Available", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                        .accessibilityLabel("iCloud is available")
                } else {
                    Label("Unavailable", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.colorTextSecondary)
                        .accessibilityLabel("iCloud is not available")
                }
            }
            .accessibilityIdentifier("icloud-status-row")
        } header: {
            Text("Status")
        } footer: {
            if viewModel.iCloudAvailable {
                Text("Backups sync to iCloud Drive on this Apple ID.")
            } else {
                Text("iCloud isn't reachable — backups save locally on this device until you sign in to iCloud.")
            }
        }
    }
}

#Preview {
    NavigationStack {
        BackupRestoreSettingsView(
            viewModel: BackupRestoreViewModel(environment: .local(config: .init(
                apiBaseURL: "",
                appGroupIdentifier: "group.org.convos.ios-local",
                relyingPartyIdentifier: "local.convos.org"
            ))),
            onRestore: { _ in }
        )
    }
}
