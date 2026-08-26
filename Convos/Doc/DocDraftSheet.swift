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
    @State private var editedSource: String
    private let originalSource: String

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
        self.originalSource = original
        _editedSource = State(initialValue: startingMarkdown)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                if let anchor = item.draft?.anchor {
                    Label(anchor, systemImage: "text.book.closed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.colorTextSecondary)
                        .padding(.horizontal, DesignConstants.Spacing.step3x)
                        .frame(minHeight: 28.0)
                        .background(.colorFillMinimal, in: Capsule())
                }

                DocEditableMarkdownView(source: $editedSource)
                    .padding(DesignConstants.Spacing.step2x)
                    .background(
                        Color.colorBackgroundRaisedSecondary,
                        in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                    )
                    .accessibilityLabel("Draft text")
                    .accessibilityHint("Editable formatted draft")
                    .accessibilityIdentifier("doc-draft-editor")

                actionButtons
            }
            .padding(DesignConstants.Spacing.step4x)
            .frame(maxWidth: 680.0)
            .frame(maxWidth: .infinity)
            .background(Color.colorBackgroundSurfaceless)
            .navigationTitle(item.headline)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("doc-draft-sheet")
    }

    private var cleanText: String {
        editedSource.trimmingCharacters(in: .whitespacesAndNewlines)
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
        .convosButtonStyle(.outline(fullWidth: true))
        .frame(maxWidth: .infinity, minHeight: 44.0)
        .disabled(!isEnabled)
    }

    private var approveButton: some View {
        Button("Approve") {
            answer(DocDraftSubmission.approvalAnswer(
                originalSource: originalSource,
                editedSource: editedSource
            ))
        }
        .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
        .frame(maxWidth: .infinity, minHeight: 44.0)
        .disabled(!isEnabled || cleanText.isEmpty)
    }

    private func answer(_ answer: DocAnswer) {
        onAnswer(answer)
        dismiss()
    }
}

enum DocDraftSubmission {
    static func approvalAnswer(originalSource: String, editedSource: String) -> DocAnswer {
        let edited: String? = editedSource == originalSource ? nil : editedSource
        return .action(.approve, edited: edited)
    }
}

private struct DocEditableMarkdownView: UIViewRepresentable {
    @Binding var source: String

    func makeCoordinator() -> Coordinator {
        Coordinator(source: $source)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = DocMarkdownTextView()
        textView.delegate = context.coordinator
        textView.attributedText = DocDraftMarkdown.attributedString(from: source)
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
        guard textView.text != source else { return }
        context.coordinator.apply(source: source, to: textView)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var source: String
        private var isApplyingUpdate: Bool = false

        init(source: Binding<String>) {
            _source = source
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingUpdate else { return }
            let updatedSource = textView.text ?? ""
            source = updatedSource
            applyStyles(to: textView)
        }

        func apply(source: String, to textView: UITextView) {
            isApplyingUpdate = true
            let selectedRange = textView.selectedRange
            textView.attributedText = DocDraftMarkdown.attributedString(from: source)
            restore(selectedRange: selectedRange, in: textView)
            textView.typingAttributes = DocDraftMarkdown.bodyAttributes
            textView.setNeedsDisplay()
            isApplyingUpdate = false
        }

        private func applyStyles(to textView: UITextView) {
            isApplyingUpdate = true
            let selectedRange = textView.selectedRange
            DocDraftMarkdown.applyStyles(to: textView.textStorage)
            restore(selectedRange: selectedRange, in: textView)
            textView.typingAttributes = DocDraftMarkdown.bodyAttributes
            textView.setNeedsDisplay()
            isApplyingUpdate = false
        }

        private func restore(selectedRange: NSRange, in textView: UITextView) {
            let location = min(selectedRange.location, textView.textStorage.length)
            let availableLength = textView.textStorage.length - location
            textView.selectedRange = NSRange(
                location: location,
                length: min(selectedRange.length, availableLength)
            )
        }
    }
}

private final class DocMarkdownTextView: UITextView {
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let bulletFont = UIFont.preferredFont(forTextStyle: .body)
        let bulletAttributes: [NSAttributedString.Key: Any] = [
            .font: bulletFont,
            .foregroundColor: UIColor.secondaryLabel,
        ]
        let bullet = "•" as NSString
        let bulletSize = bullet.size(withAttributes: bulletAttributes)

        textStorage.enumerateAttribute(.docDraftListMarker, in: fullRange) { value, range, _ in
            guard value != nil, range.location < textStorage.length else { return }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: range.location)
            let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let origin = CGPoint(
                x: textContainerInset.left + 2.0,
                y: textContainerInset.top + lineRect.midY - bulletSize.height / 2.0
            )
            bullet.draw(at: origin, withAttributes: bulletAttributes)
        }
    }
}

enum DocDraftMarkdown {
    static var bodyAttributes: [NSAttributedString.Key: Any] {
        attributes(font: .preferredFont(forTextStyle: .body))
    }

    static func attributedString(from markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: markdown)
        applyStyles(to: result)
        return result
    }

    static func applyStyles(to result: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: result.length)
        guard fullRange.length > 0 else { return }
        result.setAttributes(bodyAttributes, range: fullRange)
        let source = result.string as NSString
        var cursor = 0

        while cursor < source.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: cursor, length: 0)
            )
            let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
            let rawLine = source.substring(with: lineRange)
            styleLine(rawLine, range: lineRange, source: source, result: result)
            cursor = lineEnd
        }
    }

    private static func styleLine(
        _ rawLine: String,
        range: NSRange,
        source: NSString,
        result: NSMutableAttributedString
    ) {
        if rawLine.hasPrefix("### ") {
            styleHeading(
                markerLength: 4,
                lineRange: range,
                source: source,
                result: result,
                font: .preferredFont(forTextStyle: .headline),
                paragraphSpacing: 5.0
            )
            return
        }
        if rawLine.hasPrefix("## ") {
            styleHeading(
                markerLength: 3,
                lineRange: range,
                source: source,
                result: result,
                font: .preferredFont(forTextStyle: .title2),
                paragraphSpacing: 8.0
            )
            return
        }
        if rawLine.hasPrefix("# ") {
            styleHeading(
                markerLength: 2,
                lineRange: range,
                source: source,
                result: result,
                font: .preferredFont(forTextStyle: .title1),
                paragraphSpacing: 10.0
            )
            return
        }
        if rawLine.hasPrefix("- ") || rawLine.hasPrefix("* ") {
            styleListItem(lineRange: range, source: source, result: result)
            return
        }
        applyInlineMarkdown(
            in: range,
            source: source,
            result: result,
            font: .preferredFont(forTextStyle: .body)
        )
    }

    private static func styleHeading(
        markerLength: Int,
        lineRange: NSRange,
        source: NSString,
        result: NSMutableAttributedString,
        font: UIFont,
        paragraphSpacing: CGFloat
    ) {
        let contentRange = NSRange(
            location: lineRange.location + markerLength,
            length: lineRange.length - markerLength
        )
        result.addAttributes(attributes(font: font, paragraphSpacing: paragraphSpacing), range: lineRange)
        applyInlineMarkdown(in: contentRange, source: source, result: result, font: font)
        hideSyntax(
            in: NSRange(location: lineRange.location, length: markerLength),
            result: result
        )
    }

    private static func styleListItem(
        lineRange: NSRange,
        source: NSString,
        result: NSMutableAttributedString
    ) {
        let markerRange = NSRange(location: lineRange.location, length: 2)
        let contentRange = NSRange(location: lineRange.location + 2, length: lineRange.length - 2)
        let paragraph = paragraphStyle(paragraphSpacing: 4.0)
        paragraph.firstLineHeadIndent = 22.0
        paragraph.headIndent = 22.0
        result.addAttribute(.paragraphStyle, value: paragraph, range: lineRange)
        result.addAttribute(.docDraftListMarker, value: true, range: markerRange)
        applyInlineMarkdown(
            in: contentRange,
            source: source,
            result: result,
            font: .preferredFont(forTextStyle: .body)
        )
        hideSyntax(in: markerRange, result: result)
    }

    private static func applyInlineMarkdown(
        in range: NSRange,
        source: NSString,
        result: NSMutableAttributedString,
        font: UIFont
    ) {
        var searchRange = range
        while searchRange.length >= 4 {
            let openingRange = source.range(of: "**", options: [], range: searchRange)
            guard openingRange.location != NSNotFound else { return }
            let afterOpeningLocation = NSMaxRange(openingRange)
            let afterOpeningRange = NSRange(
                location: afterOpeningLocation,
                length: NSMaxRange(range) - afterOpeningLocation
            )
            let closingRange = source.range(of: "**", options: [], range: afterOpeningRange)
            guard closingRange.location != NSNotFound else { return }

            let boldRange = NSRange(
                location: afterOpeningLocation,
                length: closingRange.location - afterOpeningLocation
            )
            result.addAttribute(.font, value: boldFont(from: font), range: boldRange)
            hideSyntax(in: openingRange, result: result)
            hideSyntax(in: closingRange, result: result)

            let nextLocation = NSMaxRange(closingRange)
            searchRange = NSRange(location: nextLocation, length: NSMaxRange(range) - nextLocation)
        }
    }

    private static func hideSyntax(in range: NSRange, result: NSMutableAttributedString) {
        result.addAttributes([
            .font: UIFont.systemFont(ofSize: 0.1),
            .foregroundColor: UIColor.clear,
            .kern: -0.1,
        ], range: range)
    }

    private static func attributes(
        font: UIFont,
        paragraphSpacing: CGFloat = 4.0
    ) -> [NSAttributedString.Key: Any] {
        return [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraphStyle(paragraphSpacing: paragraphSpacing),
        ]
    }

    private static func paragraphStyle(paragraphSpacing: CGFloat) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3.0
        paragraph.paragraphSpacing = paragraphSpacing
        return paragraph
    }

    private static func boldFont(from font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) else { return font }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

private extension NSAttributedString.Key {
    static let docDraftListMarker: NSAttributedString.Key = NSAttributedString.Key(
        "org.convos.docDraftListMarker"
    )
}
