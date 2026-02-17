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

// MARK: - Gesture Modifier

struct MessageGestureModifier: ViewModifier {
    let message: AnyMessage
    let bubbleStyle: MessageBubbleType
    let onSingleTap: (() -> Void)?
    let onReply: (AnyMessage) -> Void

    @State private var swipeOffset: CGFloat = 0
    @State private var isPressed: Bool = false
    @State private var hasAppeared: Bool = false
    @Environment(\.messageContextMenuState) private var contextMenuState: MessageContextMenuState

    private var isSourceBubble: Bool {
        !contextMenuState.isReplyParent && contextMenuState.presentedMessage?.base.id == message.base.id
    }

    func body(content: Content) -> some View {
        content
            .environment(\.messagePressed, isPressed)
            .scaleEffect(
                isPressed && hasAppeared ? 1.03 : 1.0,
                anchor: message.base.sender.isCurrentUser ? .trailing : .leading
            )
            .opacity(isSourceBubble ? 0 : 1)
            .onAppear { hasAppeared = true }
            .background {
                if isSourceBubble {
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: SourceFrameKey.self, value: geo.frame(in: .global))
                    }
                }
            }
            .onPreferenceChange(SourceFrameKey.self) { frame in
                if isSourceBubble, let frame {
                    contextMenuState.currentSourceFrame = frame
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isPressed)
            .offset(x: swipeOffset)
            .background(alignment: .leading) {
                if swipeOffset > 0 {
                    let progress = min(swipeOffset / Constant.swipeThreshold, 1.0)
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .foregroundStyle(.tertiary)
                        .scaleEffect(0.4 + progress * 0.6)
                        .opacity(Double(progress))
                        .padding(.leading, DesignConstants.Spacing.step2x)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                GeometryReader { geometry in
                    GestureOverlayView(
                        contextMenuState: contextMenuState,
                        hasSingleTap: onSingleTap != nil,
                        onSingleTap: { onSingleTap?() },
                        onDoubleTap: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            contextMenuState.onToggleReaction?("❤️", message.base.id)
                        },
                        onLongPress: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            let frame = geometry.frame(in: .global)
                            contextMenuState.present(
                                message: message,
                                bubbleFrame: frame,
                                bubbleStyle: bubbleStyle
                            )
                        },
                        onSwipeOffsetChanged: { offset in
                            swipeOffset = offset
                        },
                        onSwipeEnded: { triggered in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                swipeOffset = 0
                            }
                            if triggered { onReply(message) }
                        },
                        onPressChanged: { pressed in
                            isPressed = pressed
                        }
                    )
                }
            }
            .accessibilityAction(named: "React") {
                contextMenuState.onToggleReaction?("❤️", message.base.id)
            }
            .accessibilityAction(named: "Reply") {
                onReply(message)
            }
    }

    private enum Constant {
        static let swipeThreshold: CGFloat = 60.0
    }
}

private struct SourceFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

extension View {
    func messageGesture(
        message: AnyMessage,
        bubbleStyle: MessageBubbleType = .normal,
        onSingleTap: (() -> Void)? = nil,
        onReply: @escaping (AnyMessage) -> Void
    ) -> some View {
        modifier(MessageGestureModifier(
            message: message,
            bubbleStyle: bubbleStyle,
            onSingleTap: onSingleTap,
            onReply: onReply
        ))
    }
}

// MARK: - Gesture Overlay (UIKit for reliable gesture disambiguation)

private struct GestureOverlayView: UIViewRepresentable {
    let contextMenuState: MessageContextMenuState
    let hasSingleTap: Bool
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void
    let onLongPress: () -> Void
    let onSwipeOffsetChanged: (CGFloat) -> Void
    let onSwipeEnded: (Bool) -> Void
    let onPressChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> GesturePassthroughView {
        let view = GesturePassthroughView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        coordinator.overlayView = view
        view.coordinator = coordinator

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
        longPress.minimumPressDuration = 0.5
        longPress.delegate = coordinator
        longPress.cancelsTouchesInView = false
        longPress.delaysTouchesBegan = false
        longPress.delaysTouchesEnded = false
        view.addGestureRecognizer(longPress)

        let doubleTap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleDoubleTap)
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = coordinator
        doubleTap.cancelsTouchesInView = false
        doubleTap.delaysTouchesBegan = false
        doubleTap.delaysTouchesEnded = false
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

        let pressTracker = UILongPressGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handlePressTracker)
        )
        pressTracker.minimumPressDuration = 0
        pressTracker.delegate = coordinator
        pressTracker.cancelsTouchesInView = false
        pressTracker.delaysTouchesBegan = false
        pressTracker.delaysTouchesEnded = false
        view.addGestureRecognizer(pressTracker)

        return view
    }

    func updateUIView(_ uiView: GesturePassthroughView, context: Context) {
        context.coordinator.contextMenuState = contextMenuState
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onSwipeOffsetChanged = onSwipeOffsetChanged
        context.coordinator.onSwipeEnded = onSwipeEnded
        context.coordinator.onPressChanged = onPressChanged
        context.coordinator.singleTapRecognizer?.isEnabled = hasSingleTap
    }

    final class GesturePassthroughView: UIView {
        weak var coordinator: Coordinator?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard bounds.contains(point) else { return nil }
            if let linkView = findLinkViewInCell(at: point) {
                return linkView
            }
            return self
        }

        private func findLinkViewInCell(at point: CGPoint) -> UIView? {
            let root = findAncestorCell()?.contentView ?? superview
            guard let root else { return nil }
            let rootPoint = convert(point, to: root)
            return findLinkView(in: root, at: rootPoint, excluding: self)
        }

        private func findLinkView(in view: UIView, at point: CGPoint, excluding: UIView) -> UIView? {
            for subview in view.subviews.reversed() {
                if subview === excluding { continue }
                let subviewPoint = view.convert(point, to: subview)
                if subview.bounds.contains(subviewPoint),
                   let linkView = subview as? (any LinkHitTestable),
                   linkView.containsLink(at: subviewPoint) {
                    return linkView
                }
                if let found = findLinkView(in: subview, at: subviewPoint, excluding: excluding) {
                    return found
                }
            }
            return nil
        }

        private func findAncestorCell() -> UICollectionViewCell? {
            var current: UIView? = superview
            while let view = current {
                if let cell = view as? UICollectionViewCell {
                    return cell
                }
                current = view.superview
            }
            return nil
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var overlayView: GesturePassthroughView?
        weak var singleTapRecognizer: UITapGestureRecognizer?
        weak var contextMenuState: MessageContextMenuState?
        var onSingleTap: (() -> Void)?
        var onDoubleTap: (() -> Void)?
        var onLongPress: (() -> Void)?
        var onSwipeOffsetChanged: ((CGFloat) -> Void)?
        var onSwipeEnded: ((Bool) -> Void)?
        var onPressChanged: ((Bool) -> Void)?

        private var isDisabled: Bool {
            contextMenuState?.isPresented ?? false
        }

        private var swipeTriggered: Bool = false
        private var panActive: Bool = false
        private var pressWorkItem: DispatchWorkItem?
        private var isPressActive: Bool = false
        private weak var cachedScrollView: UIScrollView?

        @objc func handlePan(_ pan: UIPanGestureRecognizer) {
            let threshold: CGFloat = 60.0

            switch pan.state {
            case .began:
                guard !isDisabled, isGestureInsideOverlay(pan) else {
                    panActive = false
                    return
                }
                panActive = true
                cancelPress()
                cachedScrollView = findScrollView()
                cachedScrollView?.panGestureRecognizer.isEnabled = false

            case .changed:
                guard !isDisabled, panActive else { return }
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
                guard panActive else { return }
                panActive = false
                cancelPress()
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
            guard !isDisabled, gesture.state == .began, isGestureInsideOverlay(gesture) else { return }
            onLongPress?()
            pressWorkItem?.cancel()
            pressWorkItem = nil
            isPressActive = false
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                onPressChanged?(false)
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard !isDisabled, gesture.state == .ended, isGestureInsideOverlay(gesture) else { return }
            cancelPress()
            onSingleTap?()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard !isDisabled, gesture.state == .ended, isGestureInsideOverlay(gesture) else { return }
            cancelPress()
            onDoubleTap?()
        }

        @objc func handlePressTracker(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                guard !isDisabled, isGestureInsideOverlay(gesture) else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    guard let scrollView = self.findScrollView(),
                          !scrollView.isDragging, !scrollView.isDecelerating else {
                        return
                    }
                    self.isPressActive = true
                    self.onPressChanged?(true)
                }
                pressWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            case .ended, .cancelled, .failed:
                cancelPress()
            default:
                break
            }
        }

        private func cancelPress() {
            pressWorkItem?.cancel()
            pressWorkItem = nil
            if isPressActive {
                isPressActive = false
                onPressChanged?(false)
            }
        }

        private func isGestureInsideOverlay(_ gesture: UIGestureRecognizer) -> Bool {
            guard let overlay = overlayView else { return false }
            let location = gesture.location(in: overlay)
            return overlay.bounds.contains(location)
        }

        private func findScrollView() -> UIScrollView? {
            var current: UIView? = overlayView
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
            if let lp1 = gestureRecognizer as? UILongPressGestureRecognizer,
               let lp2 = otherGestureRecognizer as? UILongPressGestureRecognizer,
               lp1.minimumPressDuration > 0, lp2.minimumPressDuration > 0 {
                return false
            }
            return true
        }
    }
}
