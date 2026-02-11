import ConvosCore
import SwiftUI
import UIKit

struct MessageInteractionModifier: ViewModifier {
    let message: AnyMessage
    let bubbleStyle: MessageBubbleType
    let onSingleTap: (() -> Void)?
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
                        isDisabled: contextMenuState.isPresented,
                        onSingleTap: onSingleTap,
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
        onSingleTap: (() -> Void)? = nil,
        onSwipeOffsetChanged: ((CGFloat) -> Void)? = nil,
        onSwipeEnded: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(MessageInteractionModifier(
            message: message,
            bubbleStyle: bubbleStyle,
            onSingleTap: onSingleTap,
            onSwipeOffsetChanged: onSwipeOffsetChanged,
            onSwipeEnded: onSwipeEnded
        ))
    }
}

// MARK: - Gesture Overlay

private struct SwipeGestureOverlay: UIViewRepresentable {
    let isDisabled: Bool
    let onSingleTap: (() -> Void)?
    let onDoubleTap: (() -> Void)?
    let onSwipeOffsetChanged: ((CGFloat) -> Void)?
    let onSwipeEnded: ((Bool) -> Void)?
    let onLongPress: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        coordinator.overlayView = view

        let pan = UIPanGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handlePan)
        )
        pan.delegate = coordinator
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        view.addGestureRecognizer(pan)

        let longPress = UILongPressGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleLongPress)
        )
        longPress.minimumPressDuration = 0.3
        longPress.delegate = coordinator
        longPress.cancelsTouchesInView = false
        longPress.delaysTouchesBegan = false
        view.addGestureRecognizer(longPress)

        let doubleTap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleDoubleTap)
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = coordinator
        view.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleSingleTap)
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = coordinator
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)
        coordinator.singleTapRecognizer = singleTap

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isDisabled = isDisabled
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.onSwipeOffsetChanged = onSwipeOffsetChanged
        context.coordinator.onSwipeEnded = onSwipeEnded
        context.coordinator.onLongPress = onLongPress
        context.coordinator.singleTapRecognizer?.isEnabled = onSingleTap != nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var overlayView: UIView?
        weak var singleTapRecognizer: UITapGestureRecognizer?
        var isDisabled: Bool = false
        var onSingleTap: (() -> Void)?
        var onDoubleTap: (() -> Void)?
        var onSwipeOffsetChanged: ((CGFloat) -> Void)?
        var onSwipeEnded: ((Bool) -> Void)?
        var onLongPress: (() -> Void)?

        private var swipeTriggered: Bool = false
        private weak var cachedScrollView: UIScrollView?
        private static let swipeThreshold: CGFloat = 60.0

        @objc func handlePan(_ pan: UIPanGestureRecognizer) {
            guard !isDisabled else { return }
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
            guard !isDisabled, gesture.state == .began else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onLongPress?()
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard !isDisabled, gesture.state == .ended else { return }
            onSingleTap?()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard !isDisabled, gesture.state == .ended else { return }
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
