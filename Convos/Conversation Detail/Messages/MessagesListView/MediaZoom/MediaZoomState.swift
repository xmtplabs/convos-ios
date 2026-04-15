import AVFoundation
import SwiftUI
import UIKit

@Observable
final class MediaZoomState: @unchecked Sendable {
    var isActive: Bool = false
    var sourceFrame: CGRect = .zero
    var currentScale: CGFloat = 1.0
    var currentTranslation: CGPoint = .zero
    var sourceImage: UIImage?
    var sourcePlayer: AVPlayer?
    var aspectRatio: CGFloat = 4.0 / 3.0
    var cornerRadius: CGFloat = 0
    var attachmentKey: String?

    var scrimAlpha: CGFloat {
        guard currentScale > 1.0 else { return 0 }
        return min((currentScale - 1.0) * 0.5, 0.4)
    }

    func beginZoom(
        sourceFrame: CGRect,
        image: UIImage?,
        player: AVPlayer?,
        aspectRatio: CGFloat,
        cornerRadius: CGFloat,
        attachmentKey: String?
    ) {
        self.sourceFrame = sourceFrame
        self.sourceImage = image
        self.sourcePlayer = player
        self.aspectRatio = aspectRatio
        self.cornerRadius = cornerRadius
        self.attachmentKey = attachmentKey
        self.currentScale = 1.0
        self.currentTranslation = .zero
        self.isActive = true
    }

    func updateZoom(scale: CGFloat, translation: CGPoint) {
        var clamped = scale
        if clamped < 1.0 {
            clamped = 1.0 + (clamped - 1.0) * 0.4
        }
        clamped = min(clamped, 3.5)
        self.currentScale = clamped
        self.currentTranslation = translation
    }

    func endZoom() {
        currentScale = 1.0
        currentTranslation = .zero
    }

    func reset() {
        isActive = false
        sourceImage = nil
        sourcePlayer = nil
        attachmentKey = nil
    }
}

private struct MediaZoomStateKey: EnvironmentKey {
    static let defaultValue: MediaZoomState = .init()
}

extension EnvironmentValues {
    var mediaZoomState: MediaZoomState {
        get { self[MediaZoomStateKey.self] }
        set { self[MediaZoomStateKey.self] = newValue }
    }
}
