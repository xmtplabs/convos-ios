import ConvosComposer
import ConvosCore
import SwiftUI

struct DocTranscriptIdentityChip: View {
    var body: some View {
        HStack(spacing: 0) {
            EmojiAvatarView(
                emoji: DocPreviewConfiguration.avatarEmoji,
                agentVerification: .verified(.convos),
                size: Constant.avatarSize
            )
            VStack(alignment: .leading, spacing: 0) {
                Text("@Doc")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                Text("History")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
        }
        .padding(DesignConstants.Spacing.step2x)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(.capsule)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("@Doc, History")
        .accessibilityIdentifier("doc-transcript-identity-chip")
    }

    private enum Constant {
        static let avatarSize: CGFloat = 36.0
    }
}
