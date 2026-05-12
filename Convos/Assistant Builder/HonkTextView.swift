import SwiftUI
import UIKit

/// `TextField(axis: .vertical)` sizes itself to its intrinsic content and
/// won't honor a tall frame's vertical alignment — short text gets pinned
/// near the bottom of the bubble and the placeholder gets clipped. This
/// `UITextView` wrapper gives us true full-frame layout: the view fills the
/// frame, then `contentInset.top` is recomputed every layout pass so the
/// text's vertical center sits at the frame's vertical center.
///
/// Newline insertion is intercepted and routed to `onSubmit` instead — the
/// editor uses return as "send/clear", not as a literal newline.
struct HonkTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: UIFont
    let textColor: UIColor
    let placeholderColor: UIColor
    let cursorColor: UIColor
    let textAlignment: NSTextAlignment
    let onSubmit: () -> Void
    let isFocused: Binding<Bool>

    func makeUIView(context: Context) -> CenteringTextView {
        let view = CenteringTextView()
        view.font = font
        view.textColor = textColor
        view.tintColor = cursorColor
        view.backgroundColor = .clear
        view.textAlignment = textAlignment
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // Scroll enabled so the UITextView respects the SwiftUI `.frame(...)`
        // constraint set by `LiveBubbleEditor`. With scroll disabled, UITextView
        // grows its intrinsicContentSize with the text and breaks the compact
        // bubble's fixed 110×56 frame.
        view.isScrollEnabled = true
        view.isEditable = true
        view.isSelectable = true
        view.isUserInteractionEnabled = true
        view.delegate = context.coordinator
        view.placeholderText = placeholder
        view.placeholderColor = placeholderColor
        view.text = text
        view.onLayout = { tv in tv.recenterContent() }
        return view
    }

    func updateUIView(_ view: CenteringTextView, context: Context) {
        if view.text != text {
            view.text = text
            view.recenterContent()
        }
        if view.placeholderText != placeholder {
            view.placeholderText = placeholder
        }
        view.placeholderColor = placeholderColor
        view.textColor = textColor
        view.tintColor = cursorColor
        view.font = font
        view.textAlignment = textAlignment
        view.pendingFocus = isFocused.wrappedValue
        view.applyPendingFocusIfPossible()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: HonkTextView

        init(_ parent: HonkTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text {
                parent.text = textView.text
            }
            (textView as? CenteringTextView)?.recenterContent()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" {
                parent.onSubmit()
                return false
            }
            return true
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused.wrappedValue {
                parent.isFocused.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused.wrappedValue {
                parent.isFocused.wrappedValue = false
            }
        }
    }
}

/// `UITextView` subclass that owns a placeholder label + a layout hook used
/// to keep the text vertically centered. The placeholder is shown only when
/// text is empty; both the placeholder and the text content are recentered
/// every time the view's bounds change or the text is updated.
final class CenteringTextView: UITextView {
    var placeholderText: String? {
        didSet {
            placeholderLabel.text = placeholderText
            updatePlaceholderVisibility()
        }
    }

    var placeholderColor: UIColor = .secondaryLabel {
        didSet { placeholderLabel.textColor = placeholderColor }
    }

    var onLayout: ((CenteringTextView) -> Void)?

    /// Desired focus state requested by SwiftUI. Applied lazily once the
    /// view is in a window — calling `becomeFirstResponder` before then
    /// fails silently and leaves us unfocused.
    var pendingFocus: Bool = false

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addSubview(placeholderLabel)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTextDidChange),
            name: UITextView.textDidChangeNotification,
            object: self
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var text: String! {
        didSet { updatePlaceholderVisibility() }
    }

    override var attributedText: NSAttributedString! {
        didSet { updatePlaceholderVisibility() }
    }

    override var font: UIFont? {
        didSet { placeholderLabel.font = font }
    }

    override var textAlignment: NSTextAlignment {
        didSet { placeholderLabel.textAlignment = textAlignment }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        recenterContent()
        layoutPlaceholder()
        onLayout?(self)
        applyPendingFocusIfPossible()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyPendingFocusIfPossible()
    }

    func applyPendingFocusIfPossible() {
        guard window != nil else { return }
        if pendingFocus, !isFirstResponder {
            becomeFirstResponder()
        } else if !pendingFocus, isFirstResponder {
            resignFirstResponder()
        }
    }

    func recenterContent() {
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let viewHeight = bounds.height
        let topInset = max((viewHeight - usedHeight) / 2, 0)
        if abs(textContainerInset.top - topInset) > 0.5 {
            textContainerInset = UIEdgeInsets(
                top: topInset,
                left: textContainerInset.left,
                bottom: 0,
                right: textContainerInset.right
            )
        }
        layoutPlaceholder()
    }

    private func layoutPlaceholder() {
        placeholderLabel.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: bounds.height
        )
    }

    private func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !(text?.isEmpty ?? true)
    }

    @objc
    private func handleTextDidChange() {
        updatePlaceholderVisibility()
        recenterContent()
    }
}
