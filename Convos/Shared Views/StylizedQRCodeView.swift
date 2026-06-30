import ConvosCore
import ConvosCoreiOS
import SwiftUI

/// Renders the stylized invite QR (rounded modules, ring-and-pupil finder
/// eyes, circular center logo) inside the rounded `#F5F5F5` tile from the
/// invite-screen design. The heavy drawing happens off the main thread in
/// `StylizedQRCodeGenerator`; this view owns the async lifecycle and the tile
/// chrome.
///
/// The generator draws the white knockout disc in the center but does not
/// rasterize the avatar into it. Instead this view overlays the app's own
/// `ConversationAvatarView`, clipped to the knockout circle. Reusing that view
/// keeps the center logo consistent with every other avatar surface and gives
/// the full fallback chain (loaded image -> emoji -> monogram -> clustered) for
/// free, so the center is never an empty hole even for a brand-new conversation
/// or before the avatar finishes loading.
struct StylizedQRCodeView: View {
    let encodedURLString: String
    /// Conversation whose avatar fills the center circle. The avatar loads and
    /// updates live through `ConversationAvatarView`.
    let conversation: Conversation
    /// Already-resolved conversation avatar, when the caller has one cached.
    /// Forwarded to `ConversationAvatarView` for instant display; nil falls
    /// back to that view's own cache/emoji/monogram chain.
    var conversationImage: UIImage?
    var foregroundColor: Color = .colorTextPrimary
    var tileColor: Color = DesignConstants.Colors.fillSubtle
    /// Side length of the square QR tile (Figma: 280.5pt).
    var tileSize: CGFloat = 280.0

    @State private var qrImage: UIImage?
    @Environment(\.displayScale) private var displayScale: CGFloat

    /// Diameter of the circular center logo as a fraction of the QR image.
    /// Mirrors `StylizedQRCodeGenerator.Options.centerLogoFraction` default so
    /// the overlaid avatar lands exactly inside the white knockout disc.
    private let centerLogoFraction: CGFloat = 0.27

    private var contentInset: CGFloat {
        tileSize * (24.0 / 280.0)
    }

    private var qrRenderSize: CGFloat {
        tileSize - contentInset * 2.0
    }

    /// Diameter of the center avatar, in tile points. The generator sizes the
    /// knockout as `qrRenderSize * centerLogoFraction`, so the overlay matches.
    private var centerLogoDiameter: CGFloat {
        qrRenderSize * centerLogoFraction
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.extraLarge)
                .fill(tileColor)
            if let qrImage {
                Image(uiImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(1.0, contentMode: .fit)
                    .frame(width: qrRenderSize, height: qrRenderSize)
                    .transition(.opacity)
            }
            ConversationAvatarView(
                conversation: conversation,
                conversationImage: conversationImage,
                size: centerLogoDiameter
            )
            .frame(width: centerLogoDiameter, height: centerLogoDiameter)
        }
        .frame(width: tileSize, height: tileSize)
        .task(id: taskKey) {
            await regenerate()
        }
        .accessibilityElement()
        .accessibilityLabel("Invite QR code")
        .accessibilityIdentifier("stylized-qr-code-view")
    }

    private var taskKey: String {
        "\(encodedURLString)|\(qrRenderSize)|\(displayScale)"
    }

    private func regenerate() async {
        let options = StylizedQRCodeGenerator.Options(
            size: qrRenderSize,
            scale: displayScale,
            foregroundColor: UIColor(foregroundColor),
            backgroundColor: .clear,
            centerLogoFraction: centerLogoFraction,
            centerImage: nil
        )
        let generated = await StylizedQRCodeGenerator.generate(from: encodedURLString, options: options)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            qrImage = generated
        }
    }
}

#Preview("With conversation avatar") {
    StylizedQRCodeView(
        encodedURLString: "https://local.convos.org/v2?i=preview-invite-token",
        conversation: .mock()
    )
    .padding()
}

#Preview("Emoji fallback") {
    StylizedQRCodeView(
        encodedURLString: "https://local.convos.org/v2?i=preview-invite-token",
        conversation: .mock(),
        conversationImage: nil
    )
    .padding()
}
