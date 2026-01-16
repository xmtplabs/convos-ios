import SwiftUI
import UIKit

struct PhotoBlurOverlayView: View {
    let image: UIImage
    let onReveal: () -> Void

    var body: some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .blur(radius: 30)
                .clipped()

            VStack(spacing: DesignConstants.Spacing.step3x) {
                Image(systemName: "eye.slash.fill")
                    .font(.title)
                    .foregroundStyle(.white)

                Text("Photo hidden")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)

                let action = { onReveal() }
                Button(action: action) {
                    Text("Tap to reveal")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignConstants.Spacing.step4x)
                        .padding(.vertical, DesignConstants.Spacing.step2x)
                        .background(.white.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .padding(DesignConstants.Spacing.step4x)
        }
    }
}

#Preview("Blur Overlay") {
    PhotoBlurOverlayView(
        image: UIImage(systemName: "photo.fill") ?? UIImage(),
        onReveal: { print("Reveal tapped") }
    )
    .frame(width: 300, height: 400)
    .background(Color.gray.opacity(0.3))
}
