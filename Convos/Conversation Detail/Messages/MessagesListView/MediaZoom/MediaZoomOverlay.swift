import AVFoundation
import SwiftUI

struct MediaZoomOverlay: View {
    let state: MediaZoomState

    @State private var isAnimatingBack: Bool = false

    private var shouldShow: Bool {
        state.isActive || isAnimatingBack
    }

    var body: some View {
        if shouldShow {
            GeometryReader { proxy in
                let localFrame = localSourceFrame(in: proxy)

                Color.black
                    .opacity(state.scrimAlpha)
                    .ignoresSafeArea()

                mediaContent
                    .frame(width: localFrame.width, height: localFrame.height)
                    .clipShape(RoundedRectangle(cornerRadius: state.cornerRadius))
                    .scaleEffect(state.currentScale)
                    .offset(x: state.currentTranslation.x, y: state.currentTranslation.y)
                    .position(x: localFrame.midX, y: localFrame.midY)
            }
            .allowsHitTesting(false)
            .onChange(of: state.isActive) { _, active in
                if !active {
                    isAnimatingBack = true
                    withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                        state.endZoom()
                    } completion: {
                        isAnimatingBack = false
                        state.reset()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var mediaContent: some View {
        if let player = state.sourcePlayer {
            InlineVideoPlayerView(player: player)
                .aspectRatio(state.aspectRatio, contentMode: .fill)
                .clipped()
        } else if let image = state.sourceImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
    }

    private func localSourceFrame(in proxy: GeometryProxy) -> CGRect {
        let globalOrigin = proxy.frame(in: .global).origin
        return CGRect(
            x: state.sourceFrame.minX - globalOrigin.x,
            y: state.sourceFrame.minY - globalOrigin.y,
            width: state.sourceFrame.width,
            height: state.sourceFrame.height
        )
    }
}
