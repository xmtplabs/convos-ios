import ConvosCore
import SwiftUI

/// Inline footer for a `convos.org/thinking:1.0` session, attached
/// beneath the message it targets. Shape mirrors the "Read" receipt row —
/// caption-sized text with a chevron — so the thinking text reads as
/// secondary metadata about the anchored message, not as its own bubble.
///
/// Used for the standalone inline-indicator case (the message is NOT the
/// last sent message). When the message would normally show a read
/// receipt, `MessagesGroupView` swaps this view for a merged row that
/// folds the thinking caption + assistant avatar into the read-receipt
/// row. `showsLeadingAvatar` is therefore typically true here — the
/// agent's avatar identifies "who is thinking" since this row stands on
/// its own. It only flips off when the thinker is the message's own
/// sender, where the bubble's leading avatar already conveys identity.
struct ThinkingIndicatorFooterView: View {
    let descriptor: ThinkingSessionDescriptor
    var showsLeadingAvatar: Bool = true
    let onTap: () -> Void

    @State private var isPulsed: Bool = false

    private var isResolved: Bool {
        !descriptor.isActive
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                if showsLeadingAvatar {
                    MessageAvatarView(
                        profile: descriptor.sender.profile,
                        size: DesignConstants.ImageSizes.extraSmallAvatar,
                        agentVerification: descriptor.sender.agentVerification
                    )
                }
                Text(descriptor.content)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.colorTextTertiary)
            }
            // Opacity pulse matches `AssistantContactCardView.PulsingSubtitle`
            // (0.5 ↔ 1.0 on a 1.2s ease-in-out loop) so a thinking session
            // reads as the same "still working" cadence as "Learning more
            // about my job". Animating opacity keeps text metrics fixed so
            // the row's height doesn't bounce. Once the session stops —
            // whether resolved with a reply or terminated without one — the
            // row freezes to full opacity as a static "thought about X"
            // marker.
            .opacity(isResolved ? 1.0 : (isPulsed ? 0.5 : 1.0))
            .animation(
                isResolved ? .default : .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: isPulsed
            )
            .onAppear { isPulsed = !isResolved }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(descriptor.sender.profile.displayName) is thinking: \(descriptor.content)")
        .accessibilityHint("Tap to see thinking details")
        .accessibilityAddTraits(.isButton)
    }
}
