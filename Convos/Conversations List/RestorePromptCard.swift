import ConvosCore
import SwiftUI

struct RestorePromptCard: View {
    let metadata: BackupBundleMetadata
    let onRestore: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("Welcome back")
                    .font(.headline)
                    .foregroundStyle(.colorTextPrimary)
                Text("A backup from \(metadata.deviceName) is available")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
                Text("\(metadata.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(metadata.inboxCount) account\(metadata.inboxCount == 1 ? "" : "s")")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
            }

            HStack(spacing: DesignConstants.Spacing.step2x) {
                Button(action: onRestore) {
                    Text("Restore")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignConstants.Spacing.step2x)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("restore-prompt-restore-button")

                Button(action: onSkip) {
                    Text("Skip")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignConstants.Spacing.step2x)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("restore-prompt-skip-button")
            }
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(.colorBackgroundRaisedSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignConstants.Spacing.step3x, style: .continuous))
    }
}

#Preview {
    RestorePromptCard(
        metadata: BackupBundleMetadata(
            createdAt: Date(),
            deviceId: "preview-device",
            deviceName: "iPhone 17",
            osString: "iOS 26.0",
            inboxCount: 3
        ),
        onRestore: {},
        onSkip: {}
    )
    .padding()
}
