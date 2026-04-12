import AVFoundation
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
    var externalSwipeOffset: Binding<CGFloat>?
    var mediaImage: UIImage?
    var mediaPlayer: AVPlayer?
    var mediaAspectRatio: CGFloat?
    var isMediaBlurred: Bool = false
    var attachmentKey: String?

    @State private var swipeOffset: CGFloat = 0
    @State private var isPressed: Bool = false
    @State private var hasAppeared: Bool = false
    @Environment(\.messageContextMenuState) private var contextMenuState: MessageContextMenuState
    @Environment(\.mediaZoomState) private var mediaZoomState: MediaZoomState

    private var isSourceBubble: Bool {
        !contextMenuState.isReplyParent && contextMenuState.presentedMessage?.messageId == message.messageId
    }

    private var doubleTapEmoji: String {
        let uniqueEmoji = Set(message.reactions.map(\.emoji))
        return uniqueEmoji.count == 1 ? uniqueEmoji.first ?? "❤️" : "❤️"
    }

    func body(content: Content) -> some View {
        content
            .environment(\.messagePressed, isPressed)
            .scaleEffect(
                isPressed && hasAppeared ? 1.03 : 1.0,
                anchor: message.sender.isCurrentUser ? .trailing : .leading
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
                swipeIndicator
            }
            .overlay {
                gestureOverlay
            }
            .accessibilityAction(named: "React") {
                contextMenuState.onToggleReaction?("❤️", message.messageId)
            }
            .accessibilityAction(named: "Reply") {
                onReply(message)
            }
    }

    @ViewBuilder
    private var swipeIndicator: some View {
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

    private var gestureOverlay: some View {
        GeometryReader { geometry in
            GestureOverlayView(
                contextMenuState: contextMenuState,
                mediaZoomState: mediaZoomState,
                hasSingleTap: onSingleTap != nil,
                onSingleTap: { onSingleTap?() },
                onDoubleTap: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    contextMenuState.onToggleReaction?(doubleTapEmoji, message.messageId)
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
                    externalSwipeOffset?.wrappedValue = offset
                },
                onSwipeEnded: { triggered in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        swipeOffset = 0
                        externalSwipeOffset?.wrappedValue = 0
                    }
                    if triggered { onReply(message) }
                },
                onPressChanged: { pressed in
                    isPressed = pressed
                },
                mediaImage: mediaImage,
                mediaPlayer: mediaPlayer,
                mediaAspectRatio: mediaAspectRatio ?? (4.0 / 3.0),
                isMediaBlurred: isMediaBlurred,
                attachmentKey: attachmentKey
            )
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
        onReply: @escaping (AnyMessage) -> Void,
        swipeOffset: Binding<CGFloat>? = nil,
        mediaImage: UIImage? = nil,
        mediaPlayer: AVPlayer? = nil,
        mediaAspectRatio: CGFloat? = nil,
        isMediaBlurred: Bool = false,
        attachmentKey: String? = nil
    ) -> some View {
        modifier(MessageGestureModifier(
            message: message,
            bubbleStyle: bubbleStyle,
            onSingleTap: onSingleTap,
            onReply: onReply,
            externalSwipeOffset: swipeOffset,
            mediaImage: mediaImage,
            mediaPlayer: mediaPlayer,
            mediaAspectRatio: mediaAspectRatio,
            isMediaBlurred: isMediaBlurred,
            attachmentKey: attachmentKey
        ))
    }
}

// MARK: - Gesture Overlay (UIKit for reliable gesture disambiguation)

private struct GestureOverlayView: UIViewRepresentable {
    let contextMenuState: MessageContextMenuState
    let mediaZoomState: MediaZoomState
    let hasSingleTap: Bool
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void
    let onLongPress: () -> Void
    let onSwipeOffsetChanged: (CGFloat) -> Void
    let onSwipeEnded: (Bool) -> Void
    let onPressChanged: (Bool) -> Void
    var mediaImage: UIImage?
    var mediaPlayer: AVPlayer?
    var mediaAspectRatio: CGFloat = 4.0 / 3.0
    var isMediaBlurred: Bool = false
    var attachmentKey: String?

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

        let pinch = UIPinchGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handlePinch)
        )
        pinch.delegate = coordinator
        pinch.cancelsTouchesInView = false
        pinch.delaysTouchesBegan = false
        pinch.delaysTouchesEnded = false
        view.addGestureRecognizer(pinch)
        coordinator.pinchRecognizer = pinch

        return view
    }

    func updateUIView(_ uiView: GesturePassthroughView, context: Context) {
        context.coordinator.contextMenuState = contextMenuState
        context.coordinator.mediaZoomState = mediaZoomState
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onSwipeOffsetChanged = onSwipeOffsetChanged
        context.coordinator.onSwipeEnded = onSwipeEnded
        context.coordinator.onPressChanged = onPressChanged
        context.coordinator.singleTapRecognizer?.isEnabled = hasSingleTap
        context.coordinator.mediaImage = mediaImage
        context.coordinator.mediaPlayer = mediaPlayer
        context.coordinator.mediaAspectRatio = mediaAspectRatio
        context.coordinator.isMediaBlurred = isMediaBlurred
        context.coordinator.attachmentKey = attachmentKey
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
        weak var pinchRecognizer: UIPinchGestureRecognizer?
        weak var contextMenuState: MessageContextMenuState?
        weak var mediaZoomState: MediaZoomState?
        var onSingleTap: (() -> Void)?
        var onDoubleTap: (() -> Void)?
        var onLongPress: (() -> Void)?
        var onSwipeOffsetChanged: ((CGFloat) -> Void)?
        var onSwipeEnded: ((Bool) -> Void)?
        var onPressChanged: ((Bool) -> Void)?

        var mediaImage: UIImage?
        var mediaPlayer: AVPlayer?
        var mediaAspectRatio: CGFloat = 4.0 / 3.0
        var isMediaBlurred: Bool = false
        var attachmentKey: String?

        private var isDisabled: Bool {
            contextMenuState?.isPresented ?? false
        }

        private var swipeTriggered: Bool = false
        private var panActive: Bool = false
        private var pinchActive: Bool = false
        private var accumulatedScale: CGFloat = 1.0
        private var initialPinchMidpoint: CGPoint = .zero
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

        @objc func handlePinch(_ pinch: UIPinchGestureRecognizer) {
            switch pinch.state {
            case .began:
                guard !isDisabled,
                      !(mediaZoomState?.isActive ?? false),
                      !isMediaBlurred,
                      mediaImage != nil || mediaPlayer != nil,
                      isGestureInsideOverlay(pinch) else {
                    return
                }
                accumulatedScale = 1.0
                pinchActive = false

            case .changed:
                guard !isDisabled,
                      mediaImage != nil || mediaPlayer != nil else { return }

                let newScale = accumulatedScale * pinch.scale
                pinch.scale = 1.0

                if !pinchActive {
                    guard abs(newScale - 1.0) > 0.05 else {
                        accumulatedScale = newScale
                        return
                    }

                    guard let overlay = overlayView else { return }
                    let frame = overlay.convert(overlay.bounds, to: nil)

                    cancelPress()
                    cachedScrollView = findScrollView()
                    cachedScrollView?.panGestureRecognizer.isEnabled = false

                    mediaZoomState?.beginZoom(
                        sourceFrame: frame,
                        image: mediaImage,
                        player: mediaPlayer,
                        aspectRatio: mediaAspectRatio,
                        cornerRadius: 0,
                        attachmentKey: attachmentKey
                    )
                    pinchActive = true
                    initialPinchMidpoint = pinch.location(in: overlay)
                }

                accumulatedScale = newScale
                mediaZoomState?.updateZoom(scale: accumulatedScale, translation: pinchTranslation(pinch))

            case .ended, .cancelled, .failed:
                if pinchActive {
                    mediaZoomState?.isActive = false
                    cachedScrollView?.panGestureRecognizer.isEnabled = true
                    cachedScrollView = nil
                }
                pinchActive = false
                accumulatedScale = 1.0

            default:
                break
            }
        }

        private func pinchTranslation(_ pinch: UIPinchGestureRecognizer) -> CGPoint {
            guard let overlay = overlayView else { return .zero }
            let currentMidpoint = pinch.location(in: overlay)
            return CGPoint(
                x: currentMidpoint.x - initialPinchMidpoint.x,
                y: currentMidpoint.y - initialPinchMidpoint.y
            )
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
            if gestureRecognizer is UIPinchGestureRecognizer {
                return !isDisabled
            }
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 2.0 && velocity.x > 0
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer {
                if otherGestureRecognizer is UILongPressGestureRecognizer
                    && (otherGestureRecognizer as? UILongPressGestureRecognizer)?.minimumPressDuration == 0 {
                    return true
                }
                return false
            }
            if let lp1 = gestureRecognizer as? UILongPressGestureRecognizer,
               let lp2 = otherGestureRecognizer as? UILongPressGestureRecognizer,
               lp1.minimumPressDuration > 0, lp2.minimumPressDuration > 0 {
                return false
            }
            return true
        }
    }
}
