#if canImport(UIKit)
import ConvosCore
import SwiftUI

/// What the Group tab shows before the conversation has any messages: the
/// invite CTA and a short explainer for how the group's agent participates.
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
        VStack(spacing: DesignConstants.Spacing.step3x) {
            inviteButton
            if !hidesText {
                Text("Your group has an agent, too")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                    .allowsHitTesting(false)
                Text("Mention \"Agent\" by name, and they’ll chime in. Or Pause them, and they can’t see a thing.")
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
#endif
