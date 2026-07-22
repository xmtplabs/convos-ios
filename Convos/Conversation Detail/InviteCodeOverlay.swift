import ConvosCore
import ConvosCoreiOS
import SwiftUI
import UIKit

// Entry points into this screen:
// - In an existing conversation: presented over the chat when the user taps
//   "Show an invite code" / the share affordance. `ConversationShareOverlay`
//   wraps this with `mode: .inConvo` and forwards the metrics hook.
// - A brand-new conversation: the first-run / empty convo presents the same
//   wrapper with `mode: .newConvo`; only the captions and nav metadata differ.
//
// The toggle + Invite/Scan tabs themselves live in `InviteCodeBody`, the single
// shared implementation. This overlay only composes that body under its floating
// liquid-glass nav for the full-screen flow; `ConversationView` embeds the same
// `InviteCodeBody` via a top `safeAreaInset` when a "Show an invite code" convo
// owns the QR inline. Both share `InviteCodeBody` so the toggle + tabs don't fork.
//
// The Invite tab renders the legacy QR glyph (`QRCodeGenerator`: rounded modules,
// Q error correction, a center hole) on the Figma `fillSubtle` rounded-56 card,
// with the conversation avatar overlaid into the center circle, plus a "Share
// invite link" button wired to the conversation invite URL and the native share
// sheet. The Scan tab swaps the QR tile for the live scanner viewfinder
// (`QRScannerView`) and an "Or scan from camera roll" button that decodes a code picked
// from the photo library. Both decoded paths feed the same `onScannedCode` handler.

/// The Scan/Invite toggle screen from the invite design. Composes the shared
/// `InviteCodeBody` (segmented control + Invite/Scan tabs) under the floating
/// liquid-glass nav.
struct InviteCodeOverlay: View {
    let conversation: Conversation
    let encodedURLString: String
    let mode: InviteCodeMode
    /// Segment selected when the screen first appears. Defaults to `.invite`
    /// (show-my-code); the in-convo Invite sheet's viewfinder button opens
    /// directly on `.scan`.
    var initialSegment: ScanInviteSegment = .invite
    @Binding var isPresented: Bool
    /// Fired with the decoded payload from either the live viewfinder or a
    /// picked screenshot. Nil keeps the Scan tab in viewfinder-only mode.
    var onScannedCode: ((String) -> Void)?
    /// Forwarded to the share sheet completion so the caller can record a
    /// share metric.
    var onShareCompleted: ((UIActivity.ActivityType?, Bool, Error?) -> Void)?
    /// Tapped on the trailing nav button (`person.crop.circle.badge.plus`).
    /// Nil hides the action.
    var onAddPeople: (() -> Void)?

    @State private var conversationImage: UIImage?

    @Environment(\.safeAreaInsets) private var safeAreaInsets: EdgeInsets

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0.0) {
                contentColumn
                Spacer(minLength: 0.0)
            }
            .padding(.top, safeAreaInsets.top + Constant.navHeight + DesignConstants.Spacing.step8x)
            floatingNav
        }
        .background(.colorBackgroundSurfaceless)
        .ignoresSafeArea()
        .cachedImage(for: conversation, into: $conversationImage)
    }

    private var backdrop: some View {
        Color.colorBackgroundSurfaceless
            .ignoresSafeArea()
    }

    private var contentColumn: some View {
        InviteCodeBody(
            conversation: conversation,
            encodedURLString: encodedURLString,
            mode: mode,
            initialSegment: initialSegment,
            onScannedCode: onScannedCode,
            onShareCompleted: onShareCompleted
        )
    }

    // MARK: - Floating nav

    private var floatingNav: some View {
        VStack {
            HStack(alignment: .center) {
                navCircleButton(icon: "chevron.backward", action: dismiss)
                    .accessibilityLabel("Back")
                Spacer(minLength: DesignConstants.Spacing.step2x)
                navTitleChip
                Spacer(minLength: DesignConstants.Spacing.step2x)
                if let onAddPeople {
                    navCircleButton(icon: "person.crop.circle.badge.plus", action: onAddPeople)
                        .accessibilityLabel("Add people")
                } else {
                    Color.clear.frame(width: Constant.navButtonSize, height: Constant.navButtonSize)
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.top, safeAreaInsets.top + DesignConstants.Spacing.step3x)
            Spacer()
        }
    }

    private func navCircleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(.colorTextPrimary)
                .frame(width: Constant.navButtonSize, height: Constant.navButtonSize)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
    }

    private var navTitleChip: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            ConversationAvatarView(conversation: conversation, conversationImage: conversationImage, size: Constant.navAvatarSize)
                .frame(width: Constant.navAvatarSize, height: Constant.navAvatarSize)
            VStack(alignment: .leading, spacing: 0.0) {
                Text(conversation.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                Text(navSubtitle)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            .lineLimit(1)
        }
        .padding(DesignConstants.Spacing.step2x)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityIdentifier("invite-nav-title-chip")
    }

    private var navSubtitle: String {
        let others: Int = conversation.membersWithoutCurrent.count
        switch mode {
        case .newConvo where others == 0:
            return "Just you"
        default:
            let total: Int = others + 1
            return total == 1 ? "Just you" : "\(total) members"
        }
    }

    // MARK: - Actions

    private func dismiss() {
        isPresented = false
    }

    private enum Constant {
        static let navHeight: CGFloat = 44.0
        static let navButtonSize: CGFloat = 44.0
        static let navAvatarSize: CGFloat = 36.0
    }
}

#Preview {
    @Previewable @State var isPresented: Bool = true
    InviteCodeOverlay(
        conversation: .mock(),
        encodedURLString: "https://local.convos.org/v2?i=preview-invite-token",
        mode: .inConvo,
        isPresented: $isPresented
    )
    .withSafeAreaEnvironment()
}
