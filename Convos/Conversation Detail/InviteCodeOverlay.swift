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
// shared implementation. This overlay only composes that body under a standard
// sheet nav bar (X close button, conversation title chip) for the sheet flow;
// `ConversationView` embeds the same `InviteCodeBody` via a top `safeAreaInset`
// when a "Show an invite code" convo owns the QR inline. Both share `InviteCodeBody` so the toggle + tabs don't fork.
//
// The Invite tab renders the legacy QR glyph (`QRCodeGenerator`: rounded modules,
// Q error correction, a center hole) on the Figma `fillSubtle` rounded-56 card,
// with the conversation avatar overlaid into the center circle, plus a "Share
// invite link" button wired to the conversation invite URL and the native share
// sheet. The Scan tab swaps the QR tile for the live scanner viewfinder
// (`QRScannerView`) and an "Or scan from camera roll" button that decodes a code picked
// from the photo library. Both decoded paths feed the same `onScannedCode` handler.

/// The Scan/Invite toggle screen from the invite design. Composes the shared
/// `InviteCodeBody` (segmented control + Invite/Scan tabs) under a standard
/// navigation bar. Presented as a `.sheet` with a `.large` detent, so the
/// system supplies the grabber, swipe-to-dismiss, and the X close button.
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

    var body: some View {
        NavigationStack {
            ZStack {
                backdrop
                VStack(spacing: 0.0) {
                    contentColumn
                    Spacer(minLength: 0.0)
                }
                .padding(.top, DesignConstants.Spacing.step8x)
            }
            .background(.colorBackgroundSurfaceless)
            .toolbarTitleDisplayMode(.inline)
            .toolbar { navigationBarContent }
        }
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

    // MARK: - Nav bar

    /// Standard sheet chrome: the system X close button in the cancellation
    /// slot (matching `ContactDetailView`), the conversation chip as the
    /// title, and Add People trailing when the caller supplies it.
    @ToolbarContentBuilder
    private var navigationBarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            let action = { dismiss() }
            Button(role: .cancel, action: action)
                .accessibilityIdentifier("invite-code-close")
        }
        ToolbarItem(placement: .principal) {
            navTitleChip
        }
        if let onAddPeople {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onAddPeople) {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .accessibilityLabel("Add people")
            }
        }
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
        static let navAvatarSize: CGFloat = 28.0
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
