import UIKit

@MainActor
protocol MessageReactionMenuCoordinatorDelegate: AnyObject {
    func messageReactionMenuCoordinator(_ coordinator: MessageReactionMenuCoordinator,
                                        previewableCellAt indexPath: IndexPath) -> PreviewableCollectionViewCell?
    func messageReactionMenuCoordinator(_ coordinator: MessageReactionMenuCoordinator,
                                        shouldPresentMenuFor cell: PreviewableCollectionViewCell) -> Bool
    func messageReactionMenuCoordinatorWasPresented(_ coordinator: MessageReactionMenuCoordinator)
    func messageReactionMenuCoordinatorWasDismissed(_ coordinator: MessageReactionMenuCoordinator)
    func messageReactionMenuViewModel(_ coordinator: MessageReactionMenuCoordinator,
                                      for indexPath: IndexPath) -> MessageReactionMenuViewModel
    var collectionView: UICollectionView { get }
}

class MessageReactionMenuCoordinator: UIPercentDrivenInteractiveTransition {
    weak var delegate: MessageReactionMenuCoordinatorDelegate?

    private var panHandler: PreviewViewPanHandler?
    private var doubleTapRecognizer: UITapGestureRecognizer?
    private var longPressRecognizer: UILongPressGestureRecognizer?

    // Store context for transition
    private var transitionSourceCell: PreviewableCollectionViewCell?
    private var transitionSourceRect: CGRect?
    private var transitionContainerView: UIView?
    private weak var currentMenuController: MessageReactionMenuController?

    // Interactive transition state
    private var isInteractive: Bool = false
    private var initialTouchPoint: CGPoint = .zero
    private var initialViewCenter: CGPoint = .zero
    private var interactivePreviewView: UIView?
    private var interactiveMenuController: MessageReactionMenuController?
    private var interactiveDirection: TransitionDirection = .presentation
    private var displayLink: CADisplayLink?
    private var gestureStartTime: CFTimeInterval = 0
    private static let activationDuration: TimeInterval = 0.4
    private enum TransitionDirection { case presentation, dismissal }

    init(delegate: MessageReactionMenuCoordinatorDelegate) {
        self.delegate = delegate
        super.init()
        setupGestureRecognizers()
    }

    private func setupGestureRecognizers() {
        guard let collectionView = delegate?.collectionView else { return }

        // Set up long press for interactive presentation
        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressRecognizer.delegate = self
        longPressRecognizer.minimumPressDuration = 0.2
        longPressRecognizer.allowableMovement = 0.0
        collectionView.addGestureRecognizer(longPressRecognizer)
        self.longPressRecognizer = longPressRecognizer

        // Set up double tap
        let doubleTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapRecognizer.numberOfTapsRequired = 2
        doubleTapRecognizer.delegate = self
        collectionView.addGestureRecognizer(doubleTapRecognizer)
        self.doubleTapRecognizer = doubleTapRecognizer
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let collectionView = delegate?.collectionView else { return }
        let location = gesture.location(in: collectionView)
        switch gesture.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(at: location),
                  let cell = delegate?.messageReactionMenuCoordinator(self, previewableCellAt: indexPath),
                  delegate?.messageReactionMenuCoordinator(self, shouldPresentMenuFor: cell) ?? true else {
                return
            }

            let cellRect = cell.convert(cell.bounds, to: collectionView.window)

            // Set up interactive state
            isInteractive = true
            initialTouchPoint = location
            interactiveDirection = .presentation

            guard let viewModel = delegate?.messageReactionMenuViewModel(self, for: indexPath) else {
                return
            }
            presentMenu(for: cell,
                        at: cellRect,
                        edge: cell.sourceCellEdge,
                        viewModel: viewModel,
                        interactive: true)
            initialViewCenter = interactivePreviewView?.center ?? cell.center

            gestureStartTime = CACurrentMediaTime()
            displayLink = CADisplayLink(target: self, selector: #selector(handleDisplayLinkTick))
            displayLink?.add(to: .main, forMode: .common)

        case .ended, .cancelled, .failed:
            if displayLink != nil {
                finish()
            } else {
                cancel()
            }
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        guard let collectionView = delegate?.collectionView else { return }
        let location = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: location),
              let cell = delegate?.messageReactionMenuCoordinator(self, previewableCellAt: indexPath) else { return }
        let cellRect = cell.convert(cell.bounds, to: collectionView.window)
        guard delegate?.messageReactionMenuCoordinator(self, shouldPresentMenuFor: cell) ?? true else { return }
        guard let viewModel = delegate?.messageReactionMenuViewModel(self, for: indexPath) else { return }
        presentMenu(for: cell,
                    at: cellRect,
                    edge: cell.sourceCellEdge,
                    viewModel: viewModel,
                    interactive: false)
    }

    private func presentMenu(for cell: PreviewableCollectionViewCell,
                             at rect: CGRect,
                             edge: MessageReactionMenuController.Configuration.Edge,
                             viewModel: MessageReactionMenuViewModel,
                             interactive: Bool = false) {
        guard let window = delegate?.collectionView.window else { return }
        let config = MessageReactionMenuController.Configuration(
            sourceCell: cell,
            sourceRect: rect,
            containerView: window,
            sourceCellEdge: edge,
            startColor: UIColor(hue: 0.0, saturation: 0.0, brightness: 0.96, alpha: 1.0)
        )
        let menuController = MessageReactionMenuController(configuration: config,
                                                           viewModel: viewModel)
        menuController.modalPresentationStyle = .custom
        menuController.transitioningDelegate = self

        transitionSourceCell = cell
        transitionSourceRect = rect
        transitionContainerView = window
        currentMenuController = menuController

        if interactive {
            interactiveMenuController = menuController
            interactivePreviewView = menuController.previewView
        }

        window.rootViewController?.topMostViewController().present(menuController, animated: true)
    }

    @objc private func handleDisplayLinkTick() {
        guard isInteractive else { return }
        let elapsed = CACurrentMediaTime() - gestureStartTime
        let progress = min(elapsed / Self.activationDuration, 1.0)
        self.update(CGFloat(progress))
        if progress >= 1.0 {
            let feedback = UIImpactFeedbackGenerator(style: .medium)
            feedback.impactOccurred(at: interactivePreviewView?.center ?? .zero)

            finish()
        }
    }

    internal override func finish() {
        displayLink?.invalidate()
        displayLink = nil
        resetInteractiveState()
        super.finish()
    }

    internal override func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        resetInteractiveState()
        super.cancel()
    }

    private func resetInteractiveState() {
        isInteractive = false
        interactivePreviewView = nil
        interactiveMenuController = nil
    }

    func interactionControllerForPresentation(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        return isInteractive ? self : nil
    }

    func interactionControllerForDismissal(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        return isInteractive ? self : nil
    }
}

extension MessageReactionMenuCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer is UILongPressGestureRecognizer,
           otherGestureRecognizer is UITapGestureRecognizer {
            return true
        }

        return false
    }
}

extension MessageReactionMenuCoordinator: UIViewControllerTransitioningDelegate {
    func animationController(forPresented presented: UIViewController,
                             presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard let cell = transitionSourceCell, let rect = transitionSourceRect else { return nil }
        return MessageReactionPresentationAnimator(
            sourceCell: cell,
            sourceRect: rect,
            isInteractive: isInteractive) { [weak self] in
                guard let self else { return }
                delegate?.messageReactionMenuCoordinatorWasPresented(self)
            } transitionEnded: {
            }
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard let cell = transitionSourceCell, let rect = transitionSourceRect else { return nil }
        return MessageReactionDismissalAnimator(
            sourceCell: cell,
            sourceRect: rect,
            isInteractive: isInteractive) {
            } transitionEnded: { [weak self] in
                guard let self else { return }
                delegate?.messageReactionMenuCoordinatorWasDismissed(self)
            }
    }
}

@MainActor
final class MessageReactionPresentationAnimator: NSObject, UIViewControllerAnimatedTransitioning, CAAnimationDelegate {
    private let sourceCell: PreviewableCollectionViewCell
    private let sourceRect: CGRect
    private let transitionBegan: () -> Void
    private let transitionEnded: () -> Void
    private let isInteractive: Bool

    static var activationDuration: CGFloat = 0.25

    init(sourceCell: PreviewableCollectionViewCell,
         sourceRect: CGRect,
         isInteractive: Bool,
         transitionBegan: @escaping () -> Void,
         transitionEnded: @escaping () -> Void) {
        self.sourceCell = sourceCell
        self.sourceRect = sourceRect
        self.transitionBegan = transitionBegan
        self.transitionEnded = transitionEnded
        self.isInteractive = isInteractive
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        isInteractive ? (MessageReactionPresentationAnimator.activationDuration + 0.01) : 0.15
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard let toVC = transitionContext.viewController(forKey: .to) as? MessageReactionMenuController else {
            transitionContext.completeTransition(false)
            return
        }

        let containerView = transitionContext.containerView
        let finalFrame = transitionContext.finalFrame(for: toVC)
        toVC.view.frame = finalFrame

        let previewView = toVC.previewView
        previewView.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        containerView.addSubview(toVC.view)
        containerView.addSubview(previewView)

        toVC.view.alpha = 0.0

        let duration = transitionDuration(using: transitionContext)
        let overshootScale: CGFloat = 1.02

        transitionBegan()

        UIView.animateKeyframes(withDuration: duration,
                                delay: 0,
                                options: [.calculationModeCubic, .beginFromCurrentState], animations: {
            UIView.addKeyframe(withRelativeStartTime: 0.0, relativeDuration: 0.0) {
                toVC.previewSourceView.alpha = 0.0
            }
            UIView.addKeyframe(withRelativeStartTime: 0.0, relativeDuration: 0.9) {
                guard !transitionContext.transitionWasCancelled else {
                    transitionContext.completeTransition(false)
                    return
                }

                previewView.transform = CGAffineTransform(scaleX: overshootScale, y: overshootScale)
            }

            UIView.addKeyframe(withRelativeStartTime: 0.9, relativeDuration: 0.4) {
                guard !transitionContext.transitionWasCancelled else {
                    transitionContext.completeTransition(false)
                    return
                }
                toVC.dimmingView.alpha = 1.0
                toVC.view.alpha = 1.0
            }
        }, completion: { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                toVC.animateReactionToEndPosition()
                toVC.animateActionButtonsToEndPosition()
                UIView.animate(withDuration: 0.5,
                               delay: 0.0,
                               usingSpringWithDamping: 0.8,
                               initialSpringVelocity: 0.2,
                               options: .beginFromCurrentState) {
                    previewView.transform = .identity
                    previewView.frame = toVC.endPosition
                } completion: { _ in
                    MainActor.assumeIsolated {
                        previewView.removeFromSuperview()
                        toVC.view.addSubview(previewView)
                    }
                }
                self.transitionEnded()
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            }
        })
    }
}

@MainActor
final class MessageReactionDismissalAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let sourceCell: PreviewableCollectionViewCell
    private let sourceRect: CGRect
    private let isInteractive: Bool
    private let transitionBegan: () -> Void
    private let transitionEnded: () -> Void

    init(sourceCell: PreviewableCollectionViewCell,
         sourceRect: CGRect,
         isInteractive: Bool,
         transitionBegan: @escaping () -> Void,
         transitionEnded: @escaping () -> Void) {
        self.sourceCell = sourceCell
        self.sourceRect = sourceRect
        self.isInteractive = isInteractive
        self.transitionBegan = transitionBegan
        self.transitionEnded = transitionEnded

        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        isInteractive ? 0.35 : 0.15
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard let fromVC = transitionContext.viewController(forKey: .from) as? MessageReactionMenuController else {
            transitionContext.completeTransition(false)
            return
        }

        transitionBegan()

        let containerView = transitionContext.containerView

        let previewView = fromVC.previewView
        containerView.addSubview(previewView)

        let duration = transitionDuration(using: transitionContext)

        UIView.animateKeyframes(withDuration: duration,
                                delay: 0,
                                options: [.calculationModeCubic, .beginFromCurrentState], animations: {
            UIView.addKeyframe(withRelativeStartTime: 0.0, relativeDuration: 0.9) {
                guard !transitionContext.transitionWasCancelled else {
                    transitionContext.completeTransition(false)
                    return
                }

                previewView.transform = .identity
                previewView.frame = fromVC.configuration.sourceRect
            }
            UIView.addKeyframe(withRelativeStartTime: 0.2, relativeDuration: 0.5) {
                fromVC.animateReactionToStartPosition()
                fromVC.animateActionButtonsToStartPosition()
            }
            UIView.addKeyframe(withRelativeStartTime: 0.0, relativeDuration: 0.3) {
                guard !transitionContext.transitionWasCancelled else {
                    transitionContext.completeTransition(false)
                    return
                }

                fromVC.dimmingView.alpha = 0.0
            }
        }, completion: { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                previewView.removeFromSuperview()
                fromVC.previewSourceView.alpha = 1.0
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                self.transitionEnded()
            }
        })
    }
}
