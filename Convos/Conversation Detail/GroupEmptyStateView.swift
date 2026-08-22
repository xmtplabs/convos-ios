import ConvosCore
import SwiftUI

/// What the Group tab shows before the conversation has any messages: the
/// invite CTA and a short explainer for how the group's agent participates.
///
/// Deliberately not a cell in the transcript. It is centred in the page and
/// fades out once a message arrives, so it never occupies a scroll position
/// or has to be removed from the list when the first message lands.
///
/// Metrics are from Figma 8070:38686 - a 12pt stack on 32pt horizontal
/// padding, a 52pt lava button, then 17/15/13pt text.
struct GroupEmptyStateView: View {
    let isInviteEnabled: Bool
    /// Drops the copy, leaving the CTA on its own. While the keyboard is up
    /// there is not room for it without crowding the composer.
    let hidesText: Bool
    let onInvite: () -> Void

    var body: some View {
        // The copy is marked per-view rather than on the stack: disabling hit
        // testing on the container would take the button with it, and the
        // container itself carries no background, so its empty area never took
        // touches to begin with. Text that did take them swallowed the pager's
        // pan, so a drag starting on the copy could not change tab.
        VStack(spacing: DesignConstants.Spacing.step3x) {
            inviteButton
            if !hidesText {
                Text("Your group has an agent, too")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                    .allowsHitTesting(false)
                Text("Mention @agent if you’d like them to speak up. Or pause them and they won’t listen at all.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .allowsHitTesting(false)
                Text("Tap @ to control their participation")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .allowsHitTesting(false)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, DesignConstants.Spacing.step8x)
    }

    private var inviteButton: some View {
        Button(action: onInvite) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                // Larger than the label, matching the design's glyph.
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: Constant.buttonIconSize))
                Text("Invite people")
                    .font(.body)
            }
            .foregroundStyle(.colorTextPrimaryInverted)
            .padding(.horizontal, DesignConstants.Spacing.step6x)
            .frame(height: Constant.buttonHeight)
            .background(Capsule().fill(.colorLava))
        }
        .buttonStyle(.plain)
        .disabled(!isInviteEnabled)
        .accessibilityIdentifier("group-empty-state-invite-button")
    }

    private enum Constant {
        static let buttonHeight: CGFloat = 52.0
        static let buttonIconSize: CGFloat = 20.0
    }
}

#Preview {
    GroupEmptyStateView(isInviteEnabled: true, hidesText: false, onInvite: {})
}
