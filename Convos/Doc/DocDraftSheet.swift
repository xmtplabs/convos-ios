import ConvosCore
import SwiftUI
import UIKit

struct DocDraftSheet: View {
    let item: DocWaitingItem
    let startsEdited: Bool
    let isEnabled: Bool
    let onAnswer: (DocAnswer) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize
    @State private var editedDraft: NSAttributedString
    private let originalVisibleText: String

    init(
        item: DocWaitingItem,
        startsEdited: Bool = false,
        isEnabled: Bool,
        onAnswer: @escaping (DocAnswer) -> Void
    ) {
        self.item = item
        self.startsEdited = startsEdited
        self.isEnabled = isEnabled
        self.onAnswer = onAnswer
        let original = item.draft?.text ?? ""
        let startingMarkdown = startsEdited ? original + "\n- Dinner: Friday at 7 PM" : original
        let originalDraft = DocDraftMarkdown.attributedString(from: original)
        self.originalVisibleText = originalDraft.string
        _editedDraft = State(initialValue: DocDraftMarkdown.attributedString(from: startingMarkdown))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                if let anchor = item.draft?.anchor {
                    Label(anchor, systemImage: "text.book.closed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DesignConstants.Spacing.step3x)
                        .frame(minHeight: 28.0)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }

                DocEditableMarkdownView(text: $editedDraft)
                    .padding(DesignConstants.Spacing.step2x)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14.0)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14.0)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1.0)
                    }
                    .accessibilityLabel("Draft text")
                    .accessibilityHint("Editable formatted draft")
                    .accessibilityIdentifier("doc-draft-editor")

                actionButtons
            }
            .padding(DesignConstants.Spacing.step4x)
            .frame(maxWidth: 680.0)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(item.headline)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("doc-draft-sheet")
    }

    private var cleanText: String {
        editedDraft.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: DesignConstants.Spacing.step3x) {
                approveButton
                discardButton
            }
        } else {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                discardButton
                approveButton
            }
        }
    }

    private var discardButton: some View {
        Button("Discard", role: .destructive) {
            answer(.action(.discard, edited: nil))
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: .infinity, minHeight: 44.0)
        .disabled(!isEnabled)
    }

    private var approveButton: some View {
        Button("Approve") {
            let edited = editedDraft.string == originalVisibleText ? nil : editedDraft.string
            answer(.action(.approve, edited: edited))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: .infinity, minHeight: 44.0)
        .disabled(!isEnabled || cleanText.isEmpty)
    }

    private func answer(_ answer: DocAnswer) {
        onAnswer(answer)
        dismiss()
    }
}

private struct DocEditableMarkdownView: UIViewRepresentable {
    @Binding var text: NSAttributedString

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.attributedText = text
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 8.0, left: 8.0, bottom: 8.0, right: 8.0)
        textView.textContainer.lineFragmentPadding = 0
        textView.typingAttributes = DocDraftMarkdown.bodyAttributes
        textView.accessibilityLabel = "Draft text"
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard !textView.attributedText.isEqual(to: text) else { return }
        context.coordinator.isApplyingUpdate = true
        let selectedRange = textView.selectedRange
        textView.attributedText = text
        textView.selectedRange = NSRange(
            location: min(selectedRange.location, text.length),
            length: 0
        )
        context.coordinator.isApplyingUpdate = false
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: NSAttributedString
        var isApplyingUpdate: Bool = false

        init(text: Binding<NSAttributedString>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingUpdate else { return }
            text = NSAttributedString(attributedString: textView.attributedText)
        }
    }
}

private enum DocDraftMarkdown {
    static var bodyAttributes: [NSAttributedString.Key: Any] {
        attributes(font: .preferredFont(forTextStyle: .body))
    }

    static func attributedString(from markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: .newlines)

        for (index, rawLine) in lines.enumerated() {
            let line = styledLine(rawLine)
            result.append(line)
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
            }
        }
        return result
    }

    private static func styledLine(_ rawLine: String) -> NSAttributedString {
        if rawLine.hasPrefix("### ") {
            return inlineMarkdown(
                String(rawLine.dropFirst(4)),
                font: .preferredFont(forTextStyle: .headline),
                paragraphSpacing: 5.0
            )
        }
        if rawLine.hasPrefix("## ") {
            return inlineMarkdown(
                String(rawLine.dropFirst(3)),
                font: .preferredFont(forTextStyle: .title2),
                paragraphSpacing: 8.0
            )
        }
        if rawLine.hasPrefix("# ") {
            return inlineMarkdown(
                String(rawLine.dropFirst(2)),
                font: .preferredFont(forTextStyle: .title1),
                paragraphSpacing: 10.0
            )
        }
        if rawLine.hasPrefix("- ") || rawLine.hasPrefix("* ") {
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = 22.0
            paragraph.paragraphSpacing = 4.0
            let line = inlineMarkdown(
                "•  " + String(rawLine.dropFirst(2)),
                font: .preferredFont(forTextStyle: .body),
                paragraphSpacing: 4.0
            ).mutableCopy() as? NSMutableAttributedString ?? NSMutableAttributedString()
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            return line
        }
        return inlineMarkdown(
            rawLine,
            font: .preferredFont(forTextStyle: .body),
            paragraphSpacing: 4.0
        )
    }

    private static func inlineMarkdown(
        _ source: String,
        font: UIFont,
        paragraphSpacing: CGFloat
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let regularAttributes = attributes(font: font, paragraphSpacing: paragraphSpacing)
        let boldAttributes = attributes(font: boldFont(from: font), paragraphSpacing: paragraphSpacing)
        var remainder = source[...]

        while let opening = remainder.range(of: "**") {
            let prefix = String(remainder[..<opening.lowerBound])
            result.append(NSAttributedString(string: prefix, attributes: regularAttributes))
            let afterOpening = remainder[opening.upperBound...]
            guard let closing = afterOpening.range(of: "**") else {
                result.append(NSAttributedString(string: String(remainder[opening.lowerBound...]), attributes: regularAttributes))
                return result
            }
            result.append(NSAttributedString(string: String(afterOpening[..<closing.lowerBound]), attributes: boldAttributes))
            remainder = afterOpening[closing.upperBound...]
        }

        result.append(NSAttributedString(string: String(remainder), attributes: regularAttributes))
        return result
    }

    private static func attributes(
        font: UIFont,
        paragraphSpacing: CGFloat = 4.0
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3.0
        paragraph.paragraphSpacing = paragraphSpacing
        return [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]
    }

    private static func boldFont(from font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) else { return font }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
