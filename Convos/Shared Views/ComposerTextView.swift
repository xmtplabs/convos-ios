import SwiftUI
import UIKit

struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let maxHeight: CGFloat
    let onSubmit: () -> Void
    let onImagePasted: (UIImage) -> Void

    func makeUIView(context: Context) -> ComposerUITextView {
        let textView = ComposerUITextView()
        textView.delegate = context.coordinator
        textView.onImagePasted = onImagePasted
        textView.font = UIFont.preferredFont(forTextStyle: .callout)
        textView.textColor = UIColor(.colorTextPrimary)
        textView.tintColor = UIColor(.colorTextPrimary)
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.accessibilityLabel = "Message input"
        textView.accessibilityIdentifier = "message-text-field"
        context.coordinator.setupPlaceholder(in: textView, placeholder: placeholder)
        return textView
    }

    func updateUIView(_ uiView: ComposerUITextView, context: Context) {
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }

        uiView.onImagePasted = onImagePasted
        uiView.isEditable = isEnabled
        uiView.isSelectable = isEnabled

        if uiView.text != text, !uiView.isPasting {
            uiView.text = text
            uiView.invalidateIntrinsicContentSize()
        }

        context.coordinator.updatePlaceholder(in: uiView, text: text, placeholder: placeholder)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        let maxWidth = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let fittingSize = uiView.sizeThatFits(CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude))
        let clampedHeight = min(fittingSize.height, maxHeight)
        uiView.isScrollEnabled = fittingSize.height > maxHeight
        return CGSize(width: maxWidth, height: clampedHeight)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: ComposerTextView
        var isUpdating: Bool = false
        private var placeholderLabel: UILabel?

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func setupPlaceholder(in textView: UITextView, placeholder: String) {
            let label = UILabel()
            label.text = placeholder
            label.font = textView.font
            label.textColor = UIColor.tertiaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isAccessibilityElement = false
            textView.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
                label.topAnchor.constraint(equalTo: textView.topAnchor),
            ])
            placeholderLabel = label
            label.isHidden = !textView.text.isEmpty
        }

        func updatePlaceholder(in textView: UITextView, text: String, placeholder: String) {
            placeholderLabel?.text = placeholder
            placeholderLabel?.font = textView.font
            placeholderLabel?.isHidden = !text.isEmpty
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating else { return }
            parent.text = textView.text
            placeholderLabel?.isHidden = !textView.text.isEmpty
            textView.invalidateIntrinsicContentSize()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" {
                parent.onSubmit()
                return false
            }
            return true
        }
    }
}

final class ComposerUITextView: UITextView {
    var onImagePasted: ((UIImage) -> Void)?
    private(set) var isPasting: Bool = false

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general

        if pasteboard.hasImages, let image = pasteboard.image {
            isPasting = true
            onImagePasted?(image)
            isPasting = false
            return
        }

        super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasImages || UIPasteboard.general.hasStrings
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
