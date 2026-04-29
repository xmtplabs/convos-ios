import ConvosCore
import SwiftUI

/// Fresh-install empty-state card shown above the (empty) conversations
/// list when `RestoreManager.findAvailableBackup` returned a compatible
/// bundle. Ported from PR #602's visual design (louis/icloud-backup):
/// "Welcome back" header + `icloud.and.arrow.down` + two-button row
/// (Skip outline / Restore filled). The user picks one and moves on.
struct RestorePromptCard: View {
    let sidecar: BackupSidecarMetadata
    let backupCount: Int
    let isRestoring: Bool
    let onRestore: () -> Void
    let onChooseBackup: (() -> Void)?
    let onStartFresh: () -> Void

    @State private var showingRestoreConfirmation: Bool = false
    @State private var showingStartFreshConfirmation: Bool = false

    var body: some View {
        let restoreAction: () -> Void = {
            showingRestoreConfirmation = true
        }
        // Two-key model: "Start fresh" is now the explicit
        // I-am-leaving-the-account signal. It rotates the synced backup
        // key, which makes existing bundles unreadable on every paired
        // device. Confirm before doing it.
        let skipAction: () -> Void = {
            showingStartFreshConfirmation = true
        }
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundStyle(.colorFillPrimary)
                        .font(.callout)
                    Text("Welcome back")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(.colorTextPrimary)
                }
                Text("A backup from \(sidecar.deviceName) is available")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
                Text(
                    "\(sidecar.createdAt.formatted(date: .abbreviated, time: .shortened)) · "
                    + "\(sidecar.conversationCount) convo\(sidecar.conversationCount == 1 ? "" : "s")"
                )
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
            }

            if isRestoring {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Restoring…")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignConstants.Spacing.step3x)
                .accessibilityIdentifier("restore-prompt-progress")
            } else {
                VStack(spacing: DesignConstants.Spacing.step2x) {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        Button(action: skipAction) {
                            Text("Skip")
                        }
                        .convosButtonStyle(.outline(fullWidth: true))
                        .accessibilityIdentifier("restore-prompt-skip-button")

                        Button(action: restoreAction) {
                            Text(backupCount > 1 ? "Restore latest" : "Restore")
                        }
                        .convosButtonStyle(.rounded(fullWidth: true))
                        .accessibilityIdentifier("restore-prompt-restore-button")
                    }

                    if let chooseAction = onChooseBackup {
                        Button(action: chooseAction) {
                            Text("Choose backup")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.colorTextSecondary)
                                .padding(.horizontal, DesignConstants.Spacing.step12x)
                                .padding(.vertical, DesignConstants.Spacing.step2x)
                        }
                        .accessibilityIdentifier("restore-prompt-choose-backup-button")
                    }
                }
            }
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(Color.colorFillMinimal, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .alert(
            "Replace this device's data?",
            isPresented: $showingRestoreConfirmation
        ) {
            Button("Replace", role: .destructive, action: onRestore)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will restore your conversations from the backup on "
                + "\(sidecar.deviceName) "
                + "(\(sidecar.createdAt.formatted(date: .abbreviated, time: .shortened))) "
                + "and replace anything on this device.\n\n"
                + "Your other devices will be signed out of this account "
                + "as part of the restore.\n\n"
                + "This can't be undone."
            )
        }
        .alert(
            "Start fresh on this Apple ID?",
            isPresented: $showingStartFreshConfirmation
        ) {
            Button("Start fresh", role: .destructive, action: onStartFresh)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Starting fresh will replace your Convos account on every device "
                + "on this Apple ID and make your existing backups unreadable. "
                + "Pick this only if you want a brand-new account.\n\n"
                + "If you're trying to come back to an existing account, "
                + "tap Cancel and use Restore instead."
            )
        }
    }
}

struct RestoreBackupChooserView: View {
    let backups: [AvailableBackup]
    let onRestore: (AvailableBackup) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var pendingRestore: AvailableBackup?
    @State private var showingRestoreConfirmation: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(backups, id: \.bundleURL) { backup in
                        let select = {
                            pendingRestore = backup
                            showingRestoreConfirmation = true
                        }
                        Button(action: select) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(backup.sidecar.deviceName)
                                    .foregroundStyle(.colorTextPrimary)
                                Text(summaryText(for: backup))
                                    .font(.caption)
                                    .foregroundStyle(.colorTextSecondary)
                            }
                        }
                        .accessibilityIdentifier("restore-backup-choice-\(backup.sidecar.deviceId)")
                    }
                } footer: {
                    Text("Backups are listed newest first. Choose the device state you want to restore.")
                }
            }
            .navigationTitle("Choose backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    let cancel = { dismiss() }
                    Button("Cancel", action: cancel)
                }
            }
            .alert(
                "Replace this device's data?",
                isPresented: $showingRestoreConfirmation,
                presenting: pendingRestore
            ) { backup in
                let restore = {
                    onRestore(backup)
                    pendingRestore = nil
                    dismiss()
                }
                Button("Replace", role: .destructive, action: restore)
                Button("Cancel", role: .cancel) {
                    pendingRestore = nil
                }
            } message: { backup in
                Text(
                    "This will restore your conversations from the backup on "
                    + "\(backup.sidecar.deviceName) "
                    + "(\(backup.sidecar.createdAt.formatted(date: .abbreviated, time: .shortened))) "
                    + "and replace anything on this device."
                )
            }
        }
    }

    private func summaryText(for backup: AvailableBackup) -> String {
        backup.sidecar.createdAt.formatted(date: .abbreviated, time: .shortened)
            + " · \(backup.sidecar.conversationCount) convo\(backup.sidecar.conversationCount == 1 ? "" : "s")"
    }
}

#Preview {
    RestorePromptCard(
        sidecar: BackupSidecarMetadata(
            deviceId: "preview",
            deviceName: "Louis's iPhone",
            osString: "ios",
            conversationCount: 12,
            schemaGeneration: "v1-single-inbox",
            appVersion: "2.3.4"
        ),
        backupCount: 2,
        isRestoring: false,
        onRestore: {},
        onChooseBackup: {},
        onStartFresh: {}
    )
    .padding()
}
