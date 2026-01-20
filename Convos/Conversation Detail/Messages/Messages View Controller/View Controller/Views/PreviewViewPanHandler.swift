import UIKit

extension CGFloat {
    func rubberClamp(maxDragDistance: CGFloat) -> CGFloat {
        let sign: CGFloat = (self >= 0) ? 1.0 : -1.0
        let absValue = abs(self)
        let clamped = CGFloat(maxDragDistance * (1 - pow(2, -absValue / (maxDragDistance / 2))))
        return sign * Swift.min(clamped, maxDragDistance * 1.5)
    }
}

@MainActor
class PreviewViewPanHandler: NSObject {
    private weak var containerView: UIView?
    private var initialTouchPoint: CGPoint = .zero
    private var initialViewCenter: CGPoint = .zero
    var maxDragDistance: CGFloat = 50.0

    /// Closure to notify when a drag should trigger a dismiss
    var onShouldDismiss: (() -> Void)?
    let targetView: (() -> UIView?)

    private var panGesture: UIPanGestureRecognizer?

    init(containerView: UIView,
         targetView: @escaping () -> UIView?) {
        self.containerView = containerView
        self.targetView = targetView
        super.init()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        containerView.addGestureRecognizer(pan)
        pan.delegate = self
        self.panGesture = pan
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let targetView = targetView(), let containerView = containerView else { return }
        let location = gesture.location(in: containerView)

        switch gesture.state {
        case .began:
            initialTouchPoint = location
            initialViewCenter = targetView.center

        case .changed:
            let translation = CGPoint(
                x: location.x - initialTouchPoint.x,
                y: location.y - initialTouchPoint.y
            )
            let elasticY = translation.y.rubberClamp(maxDragDistance: maxDragDistance)
            targetView.center = CGPoint(
                x: initialViewCenter.x,
                y: initialViewCenter.y + elasticY
            )

        case .ended, .cancelled, .failed:
            let translation = CGPoint(
                x: location.x - initialTouchPoint.x,
                y: location.y - initialTouchPoint.y
            )

            // If dragged far enough, trigger dismiss
            if abs(translation.y) > maxDragDistance {
                onShouldDismiss?()
            }

            UIView.animate(
                withDuration: 0.5,
                delay: 0,
                usingSpringWithDamping: 0.7,
                initialSpringVelocity: 0,
                options: [.curveEaseOut, .allowUserInteraction],
                animations: {
                    targetView.center = self.initialViewCenter
                }
            )
        default:
            break
        }
    }

    func removeGesture() {
        if let pan = panGesture, let containerView = containerView {
            containerView.removeGestureRecognizer(pan)
        }
    }
}

extension PreviewViewPanHandler: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}
