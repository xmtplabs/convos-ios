#if canImport(UIKit)
import ConvosCore
import ConvosCoreiOS
import SwiftUI
import UIKit

/// The invite code for a conversation: its QR card, a "Share invite link"
/// button, and a line explaining what happens when someone uses it. Nothing
/// else - scanning someone else's code is its own screen
/// (`JoinConversationView`), reached from its own button.
public struct InviteCodeCard: View {
    let conversation: Conversation
    let encodedURLString: String
    /// Whether this conversation's invite has hydrated. While false, the
    /// encoded URL is a bare `.../v2?i=` with no slug, so the card shows a
    /// loading placeholder and disables sharing instead of rendering an
    /// invalid QR/link. Always true for existing conversations; only a
    /// freshly claimed one has a pre-hydration window.
    let isInviteReady: Bool
    /// Forwarded to the share sheet completion so the caller can record a
    /// share metric.
    var onShareCompleted: ((UIActivity.ActivityType?, Bool, Error?) -> Void)?

    @State private var conversationImage: UIImage?
    @State private var qrImage: UIImage?

    @Environment(\.displayScale) private var displayScale: CGFloat
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    public init(
        conversation: Conversation,
        encodedURLString: String,
        isInviteReady: Bool = true,
        onShareCompleted: ((UIActivity.ActivityType?, Bool, Error?) -> Void)? = nil
    ) {
        self.conversation = conversation
        self.encodedURLString = encodedURLString
        self.isInviteReady = isInviteReady
        self.onShareCompleted = onShareCompleted
    }

    public var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            inviteQRTile
            shareButton
            captionBlock
        }
        .frame(width: Constant.columnWidth)
        .cachedImage(for: conversation, into: $conversationImage)
    }

    /// The Figma QR card (nodes 1/2): the `fillSubtle` rounded card, generously
    /// padded from the card edge, with the `QRCodeGenerator` glyph (rounded
    /// modules, Q error correction) and the conversation avatar overlaid into
    /// the center circle. The generator clears a square center; a circular hole
    /// mask rounds that gap so the cleared center is a clean circle, into which
    /// the standard `ConversationAvatarView` is dropped so the center matches
    /// the conversation list's avatar.
    private var inviteQRTile: some View {
        let cardSize: CGFloat = Constant.tileSize
        let qrSize: CGFloat = cardSize - Constant.qrCardPadding * 2.0
        let centerDiameter: CGFloat = qrSize * Constant.qrCenterFraction
        // The cleared square's corners would read as a square frame around the
        // round avatar; punch a circular hole sized to the square's diagonal so
        // the center reads as a clean circle. sqrt(2) reaches the corners of the
        // cleared square without enlarging it.
        let centerHoleDiameter: CGFloat = centerDiameter * 1.4142135623730951
        return ZStack {
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.extraLarge)
                .fill(DesignConstants.Colors.fillSubtle)
            if isInviteReady {
                if let qrImage {
                    Image(uiImage: qrImage)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(1.0, contentMode: .fit)
                        .frame(width: qrSize, height: qrSize)
                        .mask(qrCenterMask(holeDiameter: centerHoleDiameter))
                        .transition(.opacity)
                }
                ConversationAvatarView(
                    conversation: conversation,
                    conversationImage: conversationImage,
                    size: centerHoleDiameter
                )
                .frame(width: centerHoleDiameter, height: centerHoleDiameter)
                .clipShape(.circle)
            } else {
                ProgressView()
            }
        }
        .frame(width: cardSize, height: cardSize)
        .task(id: qrTaskKey) {
            guard isInviteReady else { return }
            await regenerateQR(size: qrSize)
        }
        .accessibilityElement()
        .accessibilityLabel("Invite QR code")
        .accessibilityIdentifier("invite-qr-code-view")
    }

    private var shareButton: some View {
        Button(action: presentShareSheet) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "square.and.arrow.up")
                Text("Share invite link")
                    .font(.callout)
            }
            .foregroundStyle(.colorTextPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: Constant.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large)
                    .fill(DesignConstants.Colors.fillSubtle)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isInviteReady)
        .accessibilityIdentifier("share-invite-link-button")
    }

    private var captionBlock: some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Text("Invite people to this convo by sharing this code")
                .font(.footnote)
                .foregroundStyle(.colorTextPrimary)
            Text("They'll be added to your Contacts")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
        }
        .multilineTextAlignment(.center)
    }

    /// Full-square mask with a centered circular hole, used to round off the
    /// corners of the generator's square cleared center so the avatar sits in a
    /// clean circular hole rather than a square one.
    private func qrCenterMask(holeDiameter: CGFloat) -> some View {
        Rectangle()
            .overlay(
                Circle()
                    .frame(width: holeDiameter, height: holeDiameter)
                    .blendMode(.destinationOut)
            )
            .compositingGroup()
    }

    private var qrTaskKey: String {
        "\(encodedURLString)|\(displayScale)|\(colorScheme)"
    }

    private func regenerateQR(size: CGFloat) async {
        let options = QRCodeGenerator.Options(
            scale: displayScale,
            displaySize: size,
            centerSpaceSize: Float(Constant.qrCenterFraction),
            foregroundColor: UIColor(.colorTextPrimary),
            backgroundColor: UIColor(DesignConstants.Colors.fillSubtle)
        )
        let generated = await QRCodeGenerator.generate(from: encodedURLString, options: options)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            qrImage = generated
        }
    }

    /// Presents the native share sheet from the top-most view controller
    /// rather than a `UIViewControllerRepresentable` background, so this card
    /// can also be hosted inside a `UIHostingConfiguration` cell, where
    /// representables are unsupported.
    private func presentShareSheet() {
        guard let presenter = UIApplication.shared.topMostViewController() else { return }
        let activityViewController = UIActivityViewController(
            activityItems: [encodedURLString],
            applicationActivities: nil
        )
        if let popover = activityViewController.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.maxY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = .up
        }
        let onShareCompleted = onShareCompleted
        activityViewController.completionWithItemsHandler = { activityType, completed, _, error in
            onShareCompleted?(activityType, completed, error)
        }
        presenter.present(activityViewController, animated: true)
    }

    private enum Constant {
        static let columnWidth: CGFloat = 283.0
        static let tileSize: CGFloat = 280.0
        /// Padding from the card edge to the QR glyph, giving the roomy
        /// QR-to-card spacing from the Figma card.
        static let qrCardPadding: CGFloat = 32.0
        /// Center-avatar diameter as a fraction of the QR. Also drives the
        /// generator's cleared center (`centerSpaceSize`) and the circular hole
        /// mask, which are kept locked to this value so the avatar exactly
        /// fills the cleared circle. 0.28 is the largest center that still
        /// reliably decodes a short real invite under Q error correction.
        static let qrCenterFraction: CGFloat = 0.28
        static let buttonHeight: CGFloat = 72.0
    }
}

#Preview {
    InviteCodeCard(
        conversation: .mock(),
        encodedURLString: "https://local.convos.org/v2?i=preview-invite-token"
    )
}
#endif
