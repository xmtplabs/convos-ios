import ConvosCore
import SwiftUI

/// Fresh-install empty-state card shown above the (empty) conversations
/// list when `RestoreManager.findAvailableBackup` returned a compatible
/// bundle. The user picks one of the two buttons:
/// - Restore — drives `onRestore`, which eventually calls
///   `RestoreManager.restoreFromBackup` after the bootstrap gate opens.
/// - Start fresh — advances the gate with
///   `RestoreBootstrapDecision.dismissedByUser` and lets the normal
///   registration flow run.
struct RestorePromptCard: View {
    let sidecar: BackupSidecarMetadata
    let onRestore: () -> Void
    let onStartFresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.icloud.fill")
                    .font(.title3)
                    .foregroundStyle(.colorFillPrimary)
                Text("Restore your conversations")
                    .font(.headline)
                    .foregroundStyle(.colorTextPrimary)
            }
            Text("We found a backup from \(sidecar.deviceName), \(sidecar.createdAt.formatted(date: .abbreviated, time: .shortened)).")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)

            VStack(spacing: 8) {
                let restoreAction = onRestore
                Button(action: restoreAction) {
                    Text("Restore from backup")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.colorFillPrimary, in: Capsule())
                        .foregroundStyle(.colorTextPrimaryInverted)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("restore-prompt-restore-button")

                let startFreshAction = onStartFresh
                Button(action: startFreshAction) {
                    Text("Start fresh")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.colorFillMinimal, in: Capsule())
                        .foregroundStyle(.colorTextPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("restore-prompt-start-fresh-button")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.colorFillMinimal, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
    }
}

#Preview {
    RestorePromptCard(
        sidecar: BackupSidecarMetadata(
            deviceId: "preview",
            deviceName: "Louis's iPhone",
            osString: "ios",
            conversationCount: 12,
            schemaGeneration: "single-inbox-v2",
            appVersion: "2.3.4"
        ),
        onRestore: {},
        onStartFresh: {}
    )
    .padding()
}
