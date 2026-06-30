import ConvosCoreiOS
import SwiftUI

/// Renders the stylized invite QR (rounded modules, ring-and-pupil finder
/// eyes, circular center logo) inside the rounded `#F5F5F5` tile from the
/// invite-screen design. The heavy drawing happens off the main thread in
/// `StylizedQRCodeGenerator`; this view owns the async lifecycle and the tile
/// chrome.
struct StylizedQRCodeView: View {
    let encodedURLString: String
    let centerImage: UIImage?
    var foregroundColor: Color = .colorTextPrimary
    var tileColor: Color = DesignConstants.Colors.fillSubtle
    /// Side length of the square QR tile (Figma: 280.5pt).
    var tileSize: CGFloat = 280.0

    @State private var qrImage: UIImage?
    @Environment(\.displayScale) private var displayScale: CGFloat

    private var contentInset: CGFloat {
        tileSize * (24.0 / 280.0)
    }

    private var qrRenderSize: CGFloat {
        tileSize - contentInset * 2.0
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
            centerImage: centerImage
        )
        let generated = await StylizedQRCodeGenerator.generate(from: encodedURLString, options: options)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            qrImage = generated
        }
    }
}

#Preview("With image logo") {
    StylizedQRCodeView(
        encodedURLString: "https://local.convos.org/v2?i=preview-invite-token",
        centerImage: UIImage(systemName: "person.crop.circle.fill")
    )
    .padding()
}

#Preview("No logo") {
    StylizedQRCodeView(
        encodedURLString: "https://local.convos.org/v2?i=preview-invite-token",
        centerImage: nil
    )
    .padding()
}
