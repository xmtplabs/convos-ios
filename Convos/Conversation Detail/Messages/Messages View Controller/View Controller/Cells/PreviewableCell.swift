import UIKit

@MainActor
protocol PreviewableCell {
    /// Returns a view to be used as preview during hard press
    func previewView() -> UIView

    /// Returns the view that was used to render the preview
    /// used to hide the original source as we animate
    var previewSourceView: UIView { get }

    /// The frame of the preview content in the cell's coordinate space
    var previewContentFrame: CGRect { get }

    var actualPreviewSourceSize: CGSize { get }

    var horizontalInset: CGFloat { get }

    var sourceCellEdge: MessageReactionMenuController.Configuration.Edge { get }
}

typealias PreviewableCollectionViewCell = PreviewableCell & UICollectionViewCell

extension PreviewableCell where Self: UICollectionViewCell {
    var previewSourceView: UIView {
        contentView
    }

    var actualPreviewSourceSize: CGSize {
        intrinsicContentSize
    }

    var horizontalInset: CGFloat {
        (layoutMargins.left + layoutMargins.right)
    }

    func previewView() -> UIView {
        guard let window else { return UIView(frame: .zero) }
        layoutIfNeeded()
        let convertedFrame = convert(previewSourceView.frame, to: window)
        // Create the snapshot
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = window.screen.scale
        format.preferredRange = .extended
        let renderer = UIGraphicsImageRenderer(bounds: previewSourceView.bounds, format: format)
        let image = renderer.image { _ in
            previewSourceView.drawHierarchy(in: contentView.bounds, afterScreenUpdates: true)
        }
        let preview = UIView(frame: convertedFrame)
        preview.layer.contents = image.cgImage
        preview.clipsToBounds = false
        return preview
    }

    var previewContentFrame: CGRect {
        contentView.bounds
    }

    var sourceCellEdge: MessageReactionMenuController.Configuration.Edge {
        // Default to .leading; override in conforming types if needed
        .leading
    }
}
