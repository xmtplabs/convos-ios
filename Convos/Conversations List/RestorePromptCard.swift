import ConvosCore
import SwiftUI

struct RestorePromptCard: View {
    let metadata: BackupBundleMetadata
    let onRestore: () -> Void
    let onSkip: () -> Void

    var body: some View {
        let restoreAction = onRestore
        let skipAction = onSkip
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
                Text("A backup from \(metadata.deviceName) is available")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
                Text("\(metadata.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(metadata.inboxCount) convo\(metadata.inboxCount == 1 ? "" : "s")")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
            }

            HStack(spacing: DesignConstants.Spacing.step2x) {
                Button(action: skipAction) {
                    Text("Skip")
                }
                .buttonStyle(CapsuleOutlineButtonStyle(fullWidth: true))
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
    }
}

private struct CapsuleOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled: Bool

    let fullWidth: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .font(.subheadline)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.vertical, DesignConstants.Spacing.step4x)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .background(Color.clear)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.colorBorderSubtle2, lineWidth: 1.0))
            .foregroundColor(isEnabled ? .colorTextPrimary : .colorTextTertiary)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
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
