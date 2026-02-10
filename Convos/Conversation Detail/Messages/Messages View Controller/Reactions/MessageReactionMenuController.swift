import Combine
import SwiftUI
import UIKit

private class ReactionsViewController: UIViewController {
    let hostingVC: UIHostingController<MessageReactionsView>

    var viewModel: MessageReactionMenuViewModel {
        didSet { update() }
    }

    init(viewModel: MessageReactionMenuViewModel) {
        self.viewModel = viewModel
        let reactionsView = MessageReactionsView(viewModel: viewModel)
        self.hostingVC = UIHostingController(rootView: reactionsView)
        self.hostingVC.sizingOptions = .intrinsicContentSize
        self.hostingVC.view.backgroundColor = .clear
        super.init(nibName: nil, bundle: nil)
        self.addChild(hostingVC)
        self.view.addSubview(hostingVC.view)
        hostingVC.didMove(toParent: self)
        self.view.layer.masksToBounds = false
        self.view.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hostingVC.view.frame = view.bounds
    }

    func update() {
        hostingVC.rootView = MessageReactionsView(viewModel: viewModel)
    }
}

class MessageReactionMenuController: UIViewController {
    struct Configuration {
        enum Edge {
            case leading, trailing
        }

        let sourceCell: PreviewableCollectionViewCell
        let sourceRect: CGRect
        let containerView: UIView
        let sourceCellEdge: Edge
        let startColor: UIColor

        // Animation timing
        static let dismissDelay: TimeInterval = 0.5

        // Positioning Constants
        static let topInset: CGFloat = 116.0
        static let betweenInset: CGFloat = 56.0
        static let maxPreviewHeight: CGFloat = 75.0
        static let spacing: CGFloat = 8.0
        static let shapeViewHeight: CGFloat = 56.0
        static let leftMargin: CGFloat = 24.0
        static let rightMargin: CGFloat = shapeViewHeight

        var shapeViewStartingSize: CGSize {
            let previewFrame = sourceRect
            let endSize = Self.shapeViewHeight
            let startSize = min(endSize, previewFrame.height)
            return CGSize(
                width: endSize,
                height: startSize
            )
        }

        @MainActor
        var endPosition: CGRect {
            let topInset = Self.topInset + containerView.safeAreaInsets.top
            let betweenInset = Self.betweenInset
            let spacing = Self.spacing
            let minY = topInset + betweenInset + spacing
            let maxY = containerView.bounds.midY - min(Self.maxPreviewHeight, sourceRect.height)
            let desiredY = min(max(sourceRect.origin.y, minY), maxY < 0.0 ? minY : maxY)
            let finalX = (containerView.bounds.width - sourceRect.width) / 2
            return CGRect(x: finalX, y: desiredY, width: sourceRect.width, height: sourceRect.height)
        }

        @MainActor
        var shapeViewEndingSize: CGSize {
            let horizontalInset = sourceCell.horizontalInset
            let endWidth = containerView.bounds.width - Self.leftMargin - Self.rightMargin - horizontalInset
            let endHeight = Self.shapeViewHeight
            return .init(width: endWidth, height: endHeight)
        }
    }

    enum ReactionsViewSize {
        case expanded,
             collapsed,
             compact
    }

    // MARK: - Properties

    let configuration: Configuration
    let actualPreviewSourceSize: CGSize
    let shapeViewStartingSize: CGSize
    let endPosition: CGRect

    let dimmingView: UIVisualEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    let previewView: UIView
    let previewSourceView: UIView
    let shapeContainerView: UIView

    fileprivate let reactionsVC: ReactionsViewController
    private let viewModel: MessageReactionMenuViewModel
    private let replyButton: UIButton = UIButton(type: .system)
    private let copyButton: UIButton = UIButton(type: .system)
    private var tapGestureRecognizer: UITapGestureRecognizer?
    private var panGestureRecognizer: UIPanGestureRecognizer?
    private var previewPanHandler: PreviewViewPanHandler?
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Initialization

    init(configuration: Configuration,
         viewModel: MessageReactionMenuViewModel) {
        self.configuration = configuration
        self.previewView = configuration.sourceCell.previewView()
        self.previewSourceView = configuration.sourceCell.previewSourceView
        self.actualPreviewSourceSize = configuration.sourceCell.actualPreviewSourceSize
        self.previewView.frame = configuration.sourceRect
        self.shapeViewStartingSize = configuration.shapeViewStartingSize
        self.endPosition = configuration.endPosition

        self.shapeContainerView = UIView(frame: .zero)
        self.shapeContainerView.backgroundColor = .clear

        viewModel.alignment = configuration.sourceCellEdge == .leading ? .leading : .trailing
        self.viewModel = viewModel
        self.reactionsVC = ReactionsViewController(viewModel: viewModel)

        super.init(nibName: nil, bundle: nil)

        viewModel.selectedEmojiPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] selectedEmoji in
                guard let self else { return }
                if selectedEmoji != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Configuration.dismissDelay) {
                        self.dismiss(animated: true)
                    }
                }
            }
            .store(in: &cancellables)

        self.tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))

        modalPresentationStyle = .custom
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        setupViews()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        reactionsVC.view.frame = shapeContainerView.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        previewPanHandler = PreviewViewPanHandler(containerView: view) { [weak self] in
            guard let self else { return nil }
            return previewView
        }
        previewPanHandler?.onShouldDismiss = { [weak self] in
            self?.dismiss(animated: true)
        }
    }

    func animateReactionToEndPosition() {
        reactionsVC.viewModel.viewState = .expanded
        animateReactionContainer(to: endPosition.origin.y - shapeContainerView.frame.height - Configuration.spacing)
    }

    func animateReactionToStartPosition() {
        let yPosition = configuration.sourceRect.origin.y
        animateReactionContainer(to: yPosition)
        reactionsVC.viewModel.viewState = .minimized
    }

    private func animateReactionContainer(to yPosition: CGFloat) {
        var shapeContainerRect = shapeContainerView.frame
        shapeContainerRect.origin.y = yPosition
        UIView.animate(
            withDuration: 0.5,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.0,
            options: [.curveEaseInOut, .layoutSubviews, .beginFromCurrentState],
            animations: { [weak self] in
                guard let self else { return }
                shapeContainerView.frame = shapeContainerRect
            }
        )
    }

    // MARK: - Setup

    private func setupViews() {
        view.backgroundColor = .clear

        dimmingView.frame = view.bounds
        dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(dimmingView)

        if let tapGestureRecognizer {
            dimmingView.addGestureRecognizer(tapGestureRecognizer)
        }

        var shapeContainerRect = configuration.sourceRect
        shapeContainerRect.size.height = configuration.shapeViewEndingSize.height
        shapeContainerView.frame = shapeContainerRect.insetBy(
            dx: configuration.sourceCell.horizontalInset / 2.0,
            dy: 0.0
        )
        view.addSubview(shapeContainerView)

        addChild(reactionsVC)
        shapeContainerView.addSubview(reactionsVC.view)
        reactionsVC.didMove(toParent: self)

        setupActionButtons()
    }

    private func setupActionButtons() {
        var replyConfig = UIButton.Configuration.filled()
        replyConfig.title = "Reply"
        replyConfig.image = UIImage(systemName: "arrowshape.turn.up.left.fill")
        replyConfig.imagePadding = 6.0
        replyConfig.cornerStyle = .capsule
        replyConfig.baseBackgroundColor = .colorBackgroundPrimary
        replyConfig.baseForegroundColor = .label
        replyConfig.contentInsets = .init(top: 10.0, leading: 16.0, bottom: 10.0, trailing: 16.0)
        replyButton.configuration = replyConfig
        replyButton.addTarget(self, action: #selector(handleReplyTap), for: .touchUpInside)
        replyButton.alpha = 0.0
        replyButton.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        view.addSubview(replyButton)
        replyButton.sizeToFit()

        var copyConfig = UIButton.Configuration.filled()
        copyConfig.title = "Copy"
        copyConfig.image = UIImage(systemName: "doc.on.doc.fill")
        copyConfig.imagePadding = 6.0
        copyConfig.cornerStyle = .capsule
        copyConfig.baseBackgroundColor = .colorBackgroundPrimary
        copyConfig.baseForegroundColor = .label
        copyConfig.contentInsets = .init(top: 10.0, leading: 16.0, bottom: 10.0, trailing: 16.0)
        copyButton.configuration = copyConfig
        copyButton.addTarget(self, action: #selector(handleCopyTap), for: .touchUpInside)
        copyButton.alpha = 0.0
        copyButton.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        view.addSubview(copyButton)
        copyButton.sizeToFit()
    }

    func animateActionButtonsToEndPosition() {
        let previewBottom = endPosition.maxY + Configuration.spacing
        let buttonSpacing: CGFloat = 8.0
        var xOffset: CGFloat = 0.0

        if viewModel.canReply {
            let replyX: CGFloat
            if configuration.sourceCellEdge == .trailing {
                replyX = endPosition.maxX - replyButton.bounds.width
            } else {
                replyX = endPosition.origin.x
            }
            replyButton.frame.origin = CGPoint(x: replyX, y: previewBottom)
            xOffset = replyButton.bounds.width + buttonSpacing

            UIView.animate(
                withDuration: 0.3,
                delay: 0.1,
                usingSpringWithDamping: 0.8,
                initialSpringVelocity: 0.0
            ) { [weak self] in
                guard let self else { return }
                replyButton.alpha = 1.0
                replyButton.transform = .identity
            }
        }

        if viewModel.copyableText != nil {
            let copyX: CGFloat
            if configuration.sourceCellEdge == .trailing {
                copyX = endPosition.maxX - xOffset - copyButton.bounds.width
            } else {
                copyX = endPosition.origin.x + xOffset
            }
            copyButton.frame.origin = CGPoint(x: copyX, y: previewBottom)

            UIView.animate(
                withDuration: 0.3,
                delay: 0.15,
                usingSpringWithDamping: 0.8,
                initialSpringVelocity: 0.0
            ) { [weak self] in
                guard let self else { return }
                copyButton.alpha = 1.0
                copyButton.transform = .identity
            }
        }
    }

    func animateActionButtonsToStartPosition() {
        UIView.animate(withDuration: 0.15) { [weak self] in
            guard let self else { return }
            replyButton.alpha = 0.0
            replyButton.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            copyButton.alpha = 0.0
            copyButton.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        }
    }

    // MARK: - Gestures

    @objc private func handleTap() {
        dismiss(animated: true)
    }

    @objc private func handleReplyTap() {
        viewModel.onReply?()
        dismiss(animated: true)
    }

    @objc private func handleCopyTap() {
        if let text = viewModel.copyableText {
            UIPasteboard.general.string = text
        }
        viewModel.onCopy?()
        dismiss(animated: true)
    }
}
