import ConvosCore
import SwiftUI
import UIKit

struct DocReaderView: View {
    @Bindable var viewModel: DocExperienceViewModel
    let initialDoc: DocStatus

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var selectedExcerpt: String?
    @State private var question: String = ""
    @State private var isSending: Bool = false
    @State private var didFailToSend: Bool = false

    private var doc: DocStatus {
        viewModel.currentDoc(for: initialDoc.id, fallback: initialDoc)
    }

    private var content: DocContent? {
        viewModel.content(for: doc.id)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let content {
                    ScrollView {
                        NativeSelectableMarkdown(markdown: content.markdown) { excerpt in
                            selectedExcerpt = excerpt
                            didFailToSend = false
                        }
                        .frame(maxWidth: 680.0)
                        .padding(.horizontal, DesignConstants.Spacing.step5x)
                        .padding(.vertical, DesignConstants.Spacing.step6x)
                        .frame(maxWidth: .infinity)
                    }
                    .background(Color.colorBackgroundSurfaceless)
                } else if viewModel.contentLoadState(for: doc.id) == .failed {
                    ContentUnavailableView {
                        Label("Doc unavailable", systemImage: "doc.badge.ellipsis")
                    } description: {
                        Text("Doc couldn't load its latest content.")
                    } actions: {
                        Button("Retry") {
                            viewModel.retryDocContent(for: doc.id)
                        }
                        .convosButtonStyle(.rounded(fullWidth: false, backgroundColor: .colorLava))
                    }
                    .accessibilityIdentifier("doc-reader-unavailable")
                } else {
                    VStack(spacing: DesignConstants.Spacing.step3x) {
                        ProgressView()
                        Text("Loading the doc…")
                            .font(.subheadline)
                            .foregroundStyle(.colorTextSecondary)
                    }
                    .accessibilityIdentifier("doc-reader-loading")
                }
            }
            .navigationTitle(doc.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if let url = doc.googleURL {
                    ToolbarItem(placement: .topBarTrailing) {
                        Link(destination: url) {
                            Label("Open in Google", systemImage: "arrow.up.right.square")
                        }
                        .accessibilityIdentifier("doc-reader-open-google")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let selectedExcerpt {
                    DocSelectionQuestionComposer(
                        excerpt: selectedExcerpt,
                        question: $question,
                        isSending: isSending,
                        didFail: didFailToSend,
                        onCancel: clearSelection,
                        onSend: sendQuestion
                    )
                }
            }
        }
        .task {
            viewModel.openRoom(for: doc)
        }
        .accessibilityIdentifier("doc-reader")
    }

    private func clearSelection() {
        selectedExcerpt = nil
        question = ""
        didFailToSend = false
    }

    private func sendQuestion() {
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectedExcerpt, !cleanQuestion.isEmpty, !isSending else { return }
        isSending = true
        didFailToSend = false
        Task { @MainActor in
            let sent = await viewModel.sendQuestion(
                cleanQuestion,
                excerpt: selectedExcerpt,
                for: doc
            )
            if sent {
                clearSelection()
            } else {
                didFailToSend = true
            }
            isSending = false
        }
    }
}

private struct DocSelectionQuestionComposer: View {
    let excerpt: String
    @Binding var question: String
    let isSending: Bool
    let didFail: Bool
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            HStack(alignment: .firstTextBaseline, spacing: DesignConstants.Spacing.step2x) {
                Text("Ask about “\(excerpt)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44.0, height: 44.0)
                }
                .accessibilityLabel("Cancel question")
            }
            if didFail {
                Text("Couldn't send. Try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step2x) {
                TextField("Ask Doc about this", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .frame(minHeight: 44.0)
                    .background(
                        Color.colorFillMinimal,
                        in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
                    )
                    .submitLabel(.send)
                    .onSubmit(onSend)
                    .accessibilityIdentifier("doc-selection-question")
                Button(action: onSend) {
                    if isSending {
                        ProgressView()
                            .frame(width: 44.0, height: 44.0)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32.0))
                            .foregroundStyle(.colorLava)
                            .frame(width: 44.0, height: 44.0)
                    }
                }
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .accessibilityLabel("Send question")
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .background(.colorBackgroundRaisedSecondary)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct NativeSelectableMarkdown: UIViewRepresentable {
    let markdown: String
    let onAskAboutSelection: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAskAboutSelection: onAskAboutSelection)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.linkTextAttributes = [.foregroundColor: UIColor.tintColor]
        textView.accessibilityIdentifier = "doc-reader-markdown"
        textView.attributedText = DocNativeMarkdownRenderer.render(markdown)
        context.coordinator.renderedMarkdown = markdown
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onAskAboutSelection = onAskAboutSelection
        guard context.coordinator.renderedMarkdown != markdown else { return }
        textView.attributedText = DocNativeMarkdownRenderer.render(markdown)
        context.coordinator.renderedMarkdown = markdown
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onAskAboutSelection: (String) -> Void
        var renderedMarkdown: String?

        init(onAskAboutSelection: @escaping (String) -> Void) {
            self.onAskAboutSelection = onAskAboutSelection
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0,
                  let swiftRange = Range(range, in: textView.text) else {
                return UIMenu(children: suggestedActions)
            }
            let excerpt = String(textView.text[swiftRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !excerpt.isEmpty else { return UIMenu(children: suggestedActions) }
            let ask = UIAction(
                title: "Ask Doc about this",
                image: UIImage(systemName: "questionmark.bubble")
            ) { [weak self] _ in
                self?.onAskAboutSelection(excerpt)
            }
            return UIMenu(children: suggestedActions + [ask])
        }
    }
}

private enum DocNativeMarkdownRenderer {
    static func render(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let block = blockStyle(for: line)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3.0
            paragraph.paragraphSpacing = block.paragraphSpacing
            paragraph.firstLineHeadIndent = block.indent
            paragraph.headIndent = block.indent

            let rendered = NSMutableAttributedString(
                string: block.text,
                attributes: [
                    .font: block.font,
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: paragraph,
                ]
            )
            addLinks(to: rendered)
            result.append(rendered)
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    private static func blockStyle(for line: String) -> BlockStyle {
        if line.hasPrefix("### ") {
            return BlockStyle(
                text: String(line.dropFirst(4)),
                font: UIFont.preferredFont(forTextStyle: .headline),
                paragraphSpacing: 6.0
            )
        }
        if line.hasPrefix("## ") {
            return BlockStyle(
                text: String(line.dropFirst(3)),
                font: UIFont.preferredFont(forTextStyle: .title2),
                paragraphSpacing: 8.0
            )
        }
        if line.hasPrefix("# ") {
            return BlockStyle(
                text: String(line.dropFirst(2)),
                font: UIFont.preferredFont(forTextStyle: .largeTitle),
                paragraphSpacing: 10.0
            )
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return BlockStyle(
                text: "• \(line.dropFirst(2))",
                font: UIFont.preferredFont(forTextStyle: .body),
                paragraphSpacing: 4.0,
                indent: 18.0
            )
        }
        return BlockStyle(
            text: line,
            font: UIFont.preferredFont(forTextStyle: .body),
            paragraphSpacing: line.isEmpty ? 4.0 : 8.0
        )
    }

    private static func addLinks(to text: NSMutableAttributedString) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return
        }
        let range = NSRange(location: 0, length: text.length)
        detector.enumerateMatches(in: text.string, options: [], range: range) { match, _, _ in
            guard let match, let url = match.url else { return }
            text.addAttribute(.link, value: url, range: match.range)
        }
    }

    private struct BlockStyle {
        let text: String
        let font: UIFont
        let paragraphSpacing: CGFloat
        var indent: CGFloat = 0
    }
}
