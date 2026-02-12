import ConvosCore
import SwiftUI
import UIKit

// MARK: - Press State Environment

private struct MessagePressedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var messagePressed: Bool {
        get { self[MessagePressedKey.self] }
        set { self[MessagePressedKey.self] = newValue }
    }
}

// MARK: - Interaction Modifier

struct MessageInteractionModifier: ViewModifier {
    let message: AnyMessage
    let bubbleStyle: MessageBubbleType
    let onSingleTap: (() -> Void)?
    let onSwipeOffsetChanged: ((CGFloat) -> Void)?
    let onSwipeEnded: ((Bool) -> Void)?

    @State private var isPressed: Bool = false
    @Environment(\.messageContextMenuState) private var contextMenuState: MessageContextMenuState

    private var isSourceBubble: Bool {
        contextMenuState.presentedMessage?.base.id == message.base.id
    }

    func body(content: Content) -> some View {
        content
            .environment(\.messagePressed, isPressed)
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
                        },
                        onPressChanged: { isPressed = $0 }
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
    let onPressChanged: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PressTrackingView {
        let view = PressTrackingView()
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
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

    func updateUIView(_ uiView: PressTrackingView, context: Context) {
        context.coordinator.isDisabled = isDisabled
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.onSwipeOffsetChanged = onSwipeOffsetChanged
        context.coordinator.onSwipeEnded = onSwipeEnded
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onPressChanged = onPressChanged
        context.coordinator.singleTapRecognizer?.isEnabled = onSingleTap != nil
    }

    final class PressTrackingView: UIView {
        weak var coordinator: Coordinator?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            coordinator?.onPressChanged?(true)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            coordinator?.onPressChanged?(false)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            coordinator?.onPressChanged?(false)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var overlayView: PressTrackingView?
        weak var singleTapRecognizer: UITapGestureRecognizer?
        var isDisabled: Bool = false
        var onSingleTap: (() -> Void)?
        var onDoubleTap: (() -> Void)?
        var onSwipeOffsetChanged: ((CGFloat) -> Void)?
        var onSwipeEnded: ((Bool) -> Void)?
        var onLongPress: (() -> Void)?
        var onPressChanged: ((Bool) -> Void)?

        private var swipeTriggered: Bool = false
        private weak var cachedScrollView: UIScrollView?
        private static let swipeThreshold: CGFloat = 60.0

        @objc func handlePan(_ pan: UIPanGestureRecognizer) {
            let threshold = Self.swipeThreshold

            switch pan.state {
            case .began:
                guard !isDisabled else { return }
                cachedScrollView = findScrollView()
                cachedScrollView?.panGestureRecognizer.isEnabled = false

            case .changed:
                guard !isDisabled else { return }
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
