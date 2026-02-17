import SwiftUI

struct PhotoEdgeGradient: View {
    let isOutgoing: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !isOutgoing {
                Color(.colorBorderEdge).frame(height: 1)
            }
            LinearGradient(
                colors: [.black, .clear],
                startPoint: isOutgoing ? .bottom : .top,
                endPoint: isOutgoing ? .top : .bottom
            )
            .frame(height: 56)
            .opacity(0.15)
            .blendMode(.multiply)
            if isOutgoing {
                Color(.colorBorderEdge).frame(height: 1)
            }
        }
    }
}

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
        .opacity(0.6)
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
