import AVFoundation
import SwiftUI

struct MediaZoomOverlay: View {
    let state: MediaZoomState

    @State private var displayScale: CGFloat = 1.0
    @State private var displayTranslation: CGPoint = .zero
    @State private var displayScrimAlpha: CGFloat = 0

    private var shouldShow: Bool {
        state.attachmentKey != nil
    }

    var body: some View {
        if shouldShow {
            GeometryReader { proxy in
                let localFrame = localSourceFrame(in: proxy)

                Color.black
                    .opacity(displayScrimAlpha)
                    .ignoresSafeArea()

                mediaContent
                    .frame(width: localFrame.width, height: localFrame.height)
                    .clipShape(RoundedRectangle(cornerRadius: state.cornerRadius))
                    .scaleEffect(displayScale)
                    .offset(x: displayTranslation.x, y: displayTranslation.y)
                    .position(x: localFrame.midX, y: localFrame.midY)
            }
            .allowsHitTesting(false)
            .onChange(of: state.currentScale) { _, newScale in
                guard state.isActive else { return }
                displayScale = newScale
                displayScrimAlpha = state.scrimAlpha
            }
            .onChange(of: state.currentTranslation) { _, newTranslation in
                guard state.isActive else { return }
                displayTranslation = newTranslation
            }
            .onChange(of: state.isActive) { _, active in
                if active {
                    displayScale = state.currentScale
                    displayTranslation = state.currentTranslation
                    displayScrimAlpha = state.scrimAlpha
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                        displayScale = 1.0
                        displayTranslation = .zero
                        displayScrimAlpha = 0
                    } completion: {
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
