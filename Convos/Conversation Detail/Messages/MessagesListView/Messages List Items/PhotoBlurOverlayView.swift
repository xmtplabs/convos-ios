import SwiftUI

struct PhotoBlurOverlayContent: View {
    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Text("Tap pic to reveal")
                .font(.caption)
                .foregroundStyle(.white)

            Image(systemName: "eye.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
        .padding(DesignConstants.Spacing.step4x)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

#Preview("Blur Overlay Content") {
    ZStack {
        Color.gray
        PhotoBlurOverlayContent()
    }
    .frame(width: 300, height: 400)
}
