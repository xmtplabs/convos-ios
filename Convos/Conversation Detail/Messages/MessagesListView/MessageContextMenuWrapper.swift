import ConvosCore
import SwiftUI
import UIKit

struct MessageInteractionModifier: ViewModifier {
    let message: AnyMessage
    let bubbleStyle: MessageBubbleType
    let onSwipeOffsetChanged: ((CGFloat) -> Void)?
    let onSwipeEnded: ((Bool) -> Void)?

    @Environment(\.messageContextMenuState) private var contextMenuState: MessageContextMenuState

    private var isSourceBubble: Bool {
        contextMenuState.presentedMessage?.base.id == message.base.id
    }

    func body(content: Content) -> some View {
        content
            .opacity(isSourceBubble ? 0 : 1)
            .overlay {
                GeometryReader { geometry in
                    SwipeGestureOverlay(
                        onDoubleTap: {
                            contextMenuState.onToggleReaction?("❤️", message.base.id)
                        },
                        onSwipeOffsetChanged: onSwipeOffsetChanged,
                        onSwipeEnded: onSwipeEnded,
                        onLongPress: {
                            let frame = geometry.frame(in: .global)
                            contextMenuState.present(
                                message: message,
                                bubbleFrame: frame,
                                bubbleStyle: bubbleStyle
                            )
                        }
                    )
                }
            }
    }
}

extension View {
    func messageInteractions(
        message: AnyMessage,
        bubbleStyle: MessageBubbleType = .normal,
        onSwipeOffsetChanged: ((CGFloat) -> Void)? = nil,
        onSwipeEnded: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(MessageInteractionModifier(
            message: message,
            bubbleStyle: bubbleStyle,
            onSwipeOffsetChanged: onSwipeOffsetChanged,
            onSwipeEnded: onSwipeEnded
        ))
    }
}

// MARK: - Swipe + Long Press Overlay

private struct SwipeGestureOverlay: UIViewRepresentable {
    let onDoubleTap: (() -> Void)?
    let onSwipeOffsetChanged: ((CGFloat) -> Void)?
    let onSwipeEnded: ((Bool) -> Void)?
    let onLongPress: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> GestureOverlayView {
        let view = GestureOverlayView()
        let coordinator = context.coordinator
        coordinator.overlayView = view
        view.onInstallGestures = { [weak coordinator] container in
            coordinator?.installGestures(on: container)
        }

        let pan = UIPanGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handlePan)
        )
        pan.delegate = coordinator
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false

        let longPress = UILongPressGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleLongPress)
        )
        longPress.minimumPressDuration = 0.3
        longPress.delegate = coordinator
        longPress.cancelsTouchesInView = false
        longPress.delaysTouchesBegan = false

        let doubleTap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleDoubleTap)
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = coordinator

        coordinator.managedRecognizers = [pan, longPress, doubleTap]

        return view
    }

    func updateUIView(_ uiView: GestureOverlayView, context: Context) {
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.onSwipeOffsetChanged = onSwipeOffsetChanged
        context.coordinator.onSwipeEnded = onSwipeEnded
        context.coordinator.onLongPress = onLongPress
    }

    final class GestureOverlayView: UIView {
        var onInstallGestures: ((UIView) -> Void)?
        private var hasInstalledGestures: Bool = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            return nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard !hasInstalledGestures, bounds.size != .zero,
                  let container = findOverlayContainer() else { return }
            hasInstalledGestures = true
            onInstallGestures?(container)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                hasInstalledGestures = false
            }
        }

        private func findOverlayContainer() -> UIView? {
            var child: UIView = self
            var current: UIView? = superview
            var depth: Int = 0
            while let view = current, depth < 15 {
                let hasOtherChildren = view.subviews.contains { subview in
                    subview !== child && !subview.isHidden && subview.frame.size != .zero
                }
                if hasOtherChildren {
                    return view
                }
                child = view
                current = view.superview
                depth += 1
            }
            return nil
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var overlayView: GestureOverlayView?
        weak var gestureHost: UIView?
        var managedRecognizers: [UIGestureRecognizer] = []
        var onDoubleTap: (() -> Void)?
        var onSwipeOffsetChanged: ((CGFloat) -> Void)?
        var onSwipeEnded: ((Bool) -> Void)?
        var onLongPress: (() -> Void)?

        private var swipeTriggered: Bool = false
        private weak var cachedScrollView: UIScrollView?
        private static let swipeThreshold: CGFloat = 60.0

        func installGestures(on container: UIView) {
            guard container !== gestureHost else { return }
            removeGesturesFromHost()
            gestureHost = container
            for gr in managedRecognizers {
                container.addGestureRecognizer(gr)
            }
        }

        private func removeGesturesFromHost() {
            guard let host = gestureHost else { return }
            for gr in managedRecognizers {
                host.removeGestureRecognizer(gr)
            }
            gestureHost = nil
        }

        @objc func handlePan(_ pan: UIPanGestureRecognizer) {
            let threshold = Self.swipeThreshold

            switch pan.state {
            case .began:
                cachedScrollView = findScrollView()
                cachedScrollView?.panGestureRecognizer.isEnabled = false

            case .changed:
                let translation = pan.translation(in: pan.view)
                let horizontal = max(translation.x, 0)
                let damped = horizontal > threshold
                    ? threshold + (horizontal - threshold) * 0.3
                    : horizontal
                onSwipeOffsetChanged?(damped)

                if horizontal >= threshold, !swipeTriggered {
                    swipeTriggered = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }

            case .ended, .cancelled, .failed:
                cachedScrollView?.panGestureRecognizer.isEnabled = true
                cachedScrollView = nil
                let didTrigger = swipeTriggered
                swipeTriggered = false
                onSwipeEnded?(didTrigger)

            default:
                break
            }
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onLongPress?()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onDoubleTap?()
        }

        private func findScrollView() -> UIScrollView? {
            var current: UIView? = overlayView?.superview
            while let view = current {
                if let scrollView = view as? UIScrollView {
                    return scrollView
                }
                current = view.superview
            }
            return nil
        }

        func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let overlayView = overlayView else { return false }
            let point = gestureRecognizer.location(in: overlayView)
            guard overlayView.bounds.contains(point) else { return false }

            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 2.0 && velocity.x > 0
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer is UILongPressGestureRecognizer,
               otherGestureRecognizer is UILongPressGestureRecognizer {
                return false
            }
            return true
        }
    }
}
