import ConvosCore
import SwiftUI

/// Fresh-install empty-state card shown above the (empty) conversations
/// list when `RestoreManager.findAvailableBackup` returned a compatible
/// bundle. Ported from PR #602's visual design (louis/icloud-backup):
/// "Welcome back" header + `icloud.and.arrow.down` + two-button row
/// (Skip outline / Restore filled). The user picks one and moves on.
struct RestorePromptCard: View {
    let sidecar: BackupSidecarMetadata
    let onRestore: () -> Void
    let onStartFresh: () -> Void

    @State private var showingRestoreConfirmation: Bool = false

    var body: some View {
        let restoreAction: () -> Void = {
            showingRestoreConfirmation = true
        }
        let skipAction = onStartFresh
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

            HStack(spacing: DesignConstants.Spacing.step2x) {
                Button(action: skipAction) {
                    Text("Skip")
                }
                .convosButtonStyle(.outline(fullWidth: true))
                .accessibilityIdentifier("restore-prompt-skip-button")

                Button(action: restoreAction) {
                    Text("Restore")
                }
                .convosButtonStyle(.rounded(fullWidth: true))
                .accessibilityIdentifier("restore-prompt-restore-button")
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
        onRestore: {},
        onStartFresh: {}
    )
    .padding()
}
