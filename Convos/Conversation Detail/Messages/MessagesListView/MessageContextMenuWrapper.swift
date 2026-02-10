import SwiftUI
import UIKit

struct MessageContextMenuWrapper<Content: View>: UIViewRepresentable {
    let timestamp: Date
    let isOutgoing: Bool
    let isTailed: Bool
    let onReply: (() -> Void)?
    let onCopy: (() -> Void)?
    let onSwipeOffsetChanged: ((CGFloat) -> Void)?
    let onSwipeEnded: ((Bool) -> Void)?
    let content: Content

    init(
        timestamp: Date,
        isOutgoing: Bool = false,
        isTailed: Bool = false,
        onReply: (() -> Void)? = nil,
        onCopy: (() -> Void)? = nil,
        onSwipeOffsetChanged: ((CGFloat) -> Void)? = nil,
        onSwipeEnded: ((Bool) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.isTailed = isTailed
        self.onReply = onReply
        self.onCopy = onCopy
        self.onSwipeOffsetChanged = onSwipeOffsetChanged
        self.onSwipeEnded = onSwipeEnded
        self.content = content()
    }

    func makeUIView(context: Context) -> HostingContainer<Content> {
        HostingContainer(
            timestamp: timestamp,
            isOutgoing: isOutgoing,
            isTailed: isTailed,
            onReply: onReply,
            onCopy: onCopy,
            onSwipeOffsetChanged: onSwipeOffsetChanged,
            onSwipeEnded: onSwipeEnded,
            rootView: content
        )
    }

    func updateUIView(_ uiView: HostingContainer<Content>, context: Context) {
        uiView.update(
            timestamp: timestamp,
            isOutgoing: isOutgoing,
            isTailed: isTailed,
            onReply: onReply,
            onCopy: onCopy,
            onSwipeOffsetChanged: onSwipeOffsetChanged,
            onSwipeEnded: onSwipeEnded,
            rootView: content
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: HostingContainer<Content>,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? uiView.window?.screen.bounds.width ?? 393.0
        let height = proposal.height ?? UIView.layoutFittingExpandedSize.height
        return uiView.sizeThatFits(CGSize(width: width, height: height))
    }
}

// MARK: - UIKit Hosting Container

final class HostingContainer<Content: View>: UIView,
    @preconcurrency UIContextMenuInteractionDelegate,
    UIGestureRecognizerDelegate {
    private var hostingController: UIHostingController<Content>
    private var timestamp: Date
    private var isOutgoing: Bool
    private var isTailed: Bool
    private var onReply: (() -> Void)?
    private var onCopy: (() -> Void)?
    private var onSwipeOffsetChanged: ((CGFloat) -> Void)?
    private var onSwipeEnded: ((Bool) -> Void)?

    private var swipeTriggered: Bool = false
    private static var swipeThreshold: CGFloat { 60.0 }

    init(
        timestamp: Date,
        isOutgoing: Bool,
        isTailed: Bool,
        onReply: (() -> Void)?,
        onCopy: (() -> Void)?,
        onSwipeOffsetChanged: ((CGFloat) -> Void)?,
        onSwipeEnded: ((Bool) -> Void)?,
        rootView: Content
    ) {
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.isTailed = isTailed
        self.onReply = onReply
        self.onCopy = onCopy
        self.onSwipeOffsetChanged = onSwipeOffsetChanged
        self.onSwipeEnded = onSwipeEnded
        self.hostingController = UIHostingController(rootView: rootView)
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear
        addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        clipsToBounds = true
        addInteraction(UIContextMenuInteraction(delegate: self))

        if onReply != nil {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipePan))
            pan.delegate = self
            addGestureRecognizer(pan)
        }
    }

    // MARK: - Swipe to Reply

    @objc private func handleSwipePan(_ pan: UIPanGestureRecognizer) {
        guard onReply != nil else { return }
        let threshold = Self.swipeThreshold

        switch pan.state {
        case .changed:
            let translation = pan.translation(in: self)
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
            let didTrigger = swipeTriggered
            swipeTriggered = false
            onSwipeEnded?(didTrigger)

        default:
            break
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y) && velocity.x > 0
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        otherGestureRecognizer.view is UIScrollView
    }

    override var intrinsicContentSize: CGSize {
        let screenWidth = window?.screen.bounds.width ?? 393.0
        let size = hostingController.sizeThatFits(in: CGSize(
            width: screenWidth,
            height: UIView.layoutFittingExpandedSize.height
        ))
        return size
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        hostingController.sizeThatFits(in: size)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        removeSystemInteractions(from: hostingController.view)
    }

    // swiftlint:disable:next function_parameter_count
    func update(
        timestamp: Date,
        isOutgoing: Bool,
        isTailed: Bool,
        onReply: (() -> Void)?,
        onCopy: (() -> Void)?,
        onSwipeOffsetChanged: ((CGFloat) -> Void)?,
        onSwipeEnded: ((Bool) -> Void)?,
        rootView: Content
    ) {
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.isTailed = isTailed
        self.onReply = onReply
        self.onCopy = onCopy
        self.onSwipeOffsetChanged = onSwipeOffsetChanged
        self.onSwipeEnded = onSwipeEnded
        hostingController.rootView = rootView
    }

    private func removeSystemInteractions(from view: UIView) {
        for interaction in view.interactions {
            // String check for "TextSelection" catches the private UITextSelectionInteraction
            // type that is not available through the public API.
            let dominated = interaction is UIContextMenuInteraction ||
                interaction is UITextInteraction ||
                String(describing: type(of: interaction)).contains("TextSelection")
            if dominated {
                view.removeInteraction(interaction)
            }
        }
        view.subviews.forEach { removeSystemInteractions(from: $0) }
    }

    // MARK: - UIContextMenuInteractionDelegate

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(
            identifier: nil,
            previewProvider: nil
        ) { [weak self] _ in
            self?.makeMenu()
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        makeTargetedPreview()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        makeTargetedPreview()
    }

    private func makeTargetedPreview() -> UITargetedPreview {
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = makeBubblePath()
        parameters.shadowPath = UIBezierPath()
        return UITargetedPreview(view: self, parameters: parameters)
    }

    private func makeBubblePath() -> UIBezierPath {
        let shape = BubbleShape.shape(isTailed: isTailed, isOutgoing: isOutgoing)
        let cgPath = shape.path(in: bounds).cgPath
        return UIBezierPath(cgPath: cgPath)
    }

    private func makeMenu() -> UIMenu {
        var actions: [UIMenuElement] = []

        if let onReply {
            let replyAction = UIAction(
                title: "Reply",
                image: UIImage(systemName: "arrowshape.turn.up.left")
            ) { _ in
                onReply()
            }
            actions.append(replyAction)
        }

        if let onCopy {
            let copyAction = UIAction(
                title: "Copy",
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                onCopy()
            }
            actions.append(copyAction)
        }

        return UIMenu(title: formattedTimestamp, children: actions)
    }

    private var formattedTimestamp: String {
        let calendar = Calendar.current
        let dayPart: String
        if calendar.isDateInToday(timestamp) {
            dayPart = "Today"
        } else if calendar.isDateInYesterday(timestamp) {
            dayPart = "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
            dayPart = formatter.string(from: timestamp)
        }
        let timeFormatter = DateFormatter()
        timeFormatter.setLocalizedDateFormatFromTemplate("j:mm")
        let timePart = timeFormatter.string(from: timestamp)
        return "\(dayPart) · \(timePart)"
    }
}

// MARK: - Bubble Shape

private enum BubbleShape {
    static func shape(isTailed: Bool, isOutgoing: Bool) -> UnevenRoundedRectangle {
        let cornerRadius = Constant.bubbleCornerRadius
        let tailRadius: CGFloat = 2.0

        if isTailed {
            if isOutgoing {
                return .rect(
                    topLeadingRadius: cornerRadius,
                    bottomLeadingRadius: cornerRadius,
                    bottomTrailingRadius: tailRadius,
                    topTrailingRadius: cornerRadius
                )
            } else {
                return .rect(
                    topLeadingRadius: cornerRadius,
                    bottomLeadingRadius: tailRadius,
                    bottomTrailingRadius: cornerRadius,
                    topTrailingRadius: cornerRadius
                )
            }
        } else {
            return .rect(
                topLeadingRadius: cornerRadius,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius,
                topTrailingRadius: cornerRadius
            )
        }
    }
}
