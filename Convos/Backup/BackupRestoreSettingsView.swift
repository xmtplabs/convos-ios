import ConvosCore
import SwiftUI

struct BackupRestoreSettingsView: View {
    @Bindable var viewModel: BackupRestoreViewModel
    let onRestore: (BackupSidecarMetadata) -> Void

    @State private var showingRestoreConfirmation: Bool = false
    @State private var pendingRestoreSidecar: BackupSidecarMetadata?

    var body: some View {
        List {
            backUpSection()
            if let sidecar = viewModel.availableRestore {
                restoreSection(sidecar: sidecar)
            }
            if let failure = viewModel.pendingArchiveImportFailure {
                partialRestoreSection(failure: failure)
            }
            if !viewModel.iCloudAvailable {
                iCloudSection()
            }
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
                if let sidecar = pendingRestoreSidecar {
                    onRestore(sidecar)
                }
                pendingRestoreSidecar = nil
            }
            Button("Restore", role: .destructive, action: confirm)
            Button("Cancel", role: .cancel) {
                pendingRestoreSidecar = nil
            }
        } message: {
            Text("This will replace the data on this device with the backup. You can't undo this.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func backUpSection() -> some View {
        Section {
            let backUp: @MainActor () -> Void = {
                Task { await viewModel.backUpNow() }
            }
            Button(action: backUp) {
                HStack {
                    Text("Back up now")
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    if viewModel.isBackupInProgress {
                        ProgressView()
                    }
                }
            }
            .disabled(viewModel.isBackupInProgress)
            .accessibilityIdentifier("back-up-now-button")

            if let last = viewModel.lastBackupAt {
                HStack {
                    Text("Last backup")
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    Text(last.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.colorTextSecondary)
                }
            }
        } footer: {
            if let error = viewModel.lastError {
                Text("Backup failed: \(error.localizedDescription)")
                    .foregroundStyle(.colorLava)
            } else {
                Text("Convos backs up your conversations daily and stores them in iCloud.")
            }
        }
    }

    @ViewBuilder
    private func restoreSection(sidecar: BackupSidecarMetadata) -> some View {
        Section {
            let restore = {
                pendingRestoreSidecar = sidecar
                showingRestoreConfirmation = true
            }
            Button(action: restore) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Restore from \(sidecar.deviceName)")
                        .foregroundStyle(.colorTextPrimary)
                    Text(sidecar.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
            }
            .accessibilityIdentifier("restore-from-backup-button")
        } header: {
            Text("Available restore")
        } footer: {
            Text("Replaces this device's conversations and messages with the backup.")
        }
    }

    @ViewBuilder
    private func partialRestoreSection(failure: PendingArchiveImportFailure) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Message history wasn't fully restored")
                    .foregroundStyle(.colorLava)
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
    private func iCloudSection() -> some View {
        Section {
            HStack {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.colorLava)
                Text("iCloud isn't available. Backups are saved locally until you sign in to iCloud.")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
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
