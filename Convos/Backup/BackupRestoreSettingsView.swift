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
            let otherBackups = Array(viewModel.availableRestores.dropFirst())
            if !otherBackups.isEmpty {
                otherBackupsSection(backups: otherBackups)
            }
            if let failure = viewModel.pendingArchiveImportFailure {
                partialRestoreSection(failure: failure)
            }
            statusSection()
        }
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.refresh() }
        .alert(
            "Replace this device's data?",
            isPresented: $showingRestoreConfirmation,
            presenting: pendingRestore
        ) { available in
            let confirm = {
                onRestore(available)
                pendingRestore = nil
            }
            Button("Replace", role: .destructive, action: confirm)
            Button("Cancel", role: .cancel) {
                pendingRestore = nil
            }
        } message: { available in
            Text(
                "This will erase all conversations, drafts, and settings on "
                + "this device and replace them with the backup from "
                + "\(available.sidecar.deviceName) "
                + "(\(available.sidecar.createdAt.formatted(date: .abbreviated, time: .shortened))).\n\n"
                + "Your other devices will be signed out of this account as "
                + "part of the restore.\n\n"
                + "This can't be undone."
            )
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
                            .foregroundStyle(viewModel.canBackUp ? .colorTextPrimary : .colorTextSecondary)
                        Spacer()
                        Image(systemName: "icloud.and.arrow.up")
                            .foregroundStyle(.colorTextSecondary)
                    }
                }
                .disabled(!viewModel.canBackUp)
                .accessibilityIdentifier("back-up-now-button")
            }
        } header: {
            Text("Backup")
        } footer: {
            if let error = viewModel.lastError {
                Text("Backup failed: \(error.localizedDescription)")
                    .foregroundStyle(.colorLava)
            } else if !viewModel.canBackUp {
                Text("Start a conversation to enable backups.")
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
            restoreButton(
                title: viewModel.availableRestores.count > 1 ? "Restore latest backup" : "Restore from backup",
                available: available,
                identifier: "restore-from-backup-button"
            )
        } header: {
            Text("Restore")
        }
    }

    @ViewBuilder
    private func otherBackupsSection(backups: [AvailableBackup]) -> some View {
        Section {
            ForEach(backups, id: \.bundleURL) { available in
                restoreButton(
                    title: available.sidecar.deviceName,
                    available: available,
                    identifier: "restore-backup-\(available.sidecar.deviceId)"
                )
            }
        } header: {
            Text("Other backups")
        } footer: {
            Text("Choose a different compatible backup if the latest one is not the device state you want to restore.")
        }
    }

    private func restoreButton(title: String, available: AvailableBackup, identifier: String) -> some View {
        let restore = {
            pendingRestore = available
            showingRestoreConfirmation = true
        }
        return Button(action: restore) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.colorTextPrimary)
                    Text(summaryText(for: available))
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
                Spacer()
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .accessibilityIdentifier(identifier)
    }

    private func summaryText(for available: AvailableBackup) -> String {
        "From \(available.sidecar.deviceName) · "
            + "\(available.sidecar.createdAt.formatted(date: .abbreviated, time: .shortened)) · "
            + "\(available.sidecar.conversationCount) convo\(available.sidecar.conversationCount == 1 ? "" : "s")"
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
