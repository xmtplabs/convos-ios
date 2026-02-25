import SwiftUI
import UIKit

struct LinkDetectingTextView: View {
    private let text: String
    private let linkColor: Color?
    private let foregroundColor: Color
    private let font: UIFont

    init(
        _ text: String,
        linkColor: Color? = nil,
        foregroundColor: Color = .primary,
        font: UIFont = .preferredFont(forTextStyle: .callout)
    ) {
        self.text = text
        self.linkColor = linkColor
        self.foregroundColor = foregroundColor
        self.font = font
    }

    var body: some View {
        LinkTextViewRepresentable(
            text: text,
            font: font,
            textColor: UIColor(foregroundColor),
            linkColor: linkColor.map { UIColor($0) }
        )
    }
}

private struct LinkTextViewRepresentable: UIViewRepresentable {
    let text: String
    let font: UIFont
    let textColor: UIColor
    let linkColor: UIColor?

    func makeUIView(context: Context) -> LinkTextView {
        let view = LinkTextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.dataDetectorTypes = .link
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: LinkTextView, context: Context) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 0

        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
        ])

        uiView.attributedText = attributed
        uiView.isSelectable = true

        if let linkColor {
            uiView.linkTextAttributes = [
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        } else {
            uiView.linkTextAttributes = [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LinkTextView, context: Context) -> CGSize? {
        let maxWidth = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let size = uiView.sizeThatFits(CGSize(width: maxWidth, height: UIView.layoutFittingExpandedSize.height))
        return size
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        func textView(
            _ textView: UITextView,
            shouldInteractWith url: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            UIApplication.shared.open(url)
            return false
        }
    }
}

protocol LinkHitTestable: UIView {
    func containsLink(at point: CGPoint) -> Bool
}

final class LinkTextView: UITextView, LinkHitTestable {
    convenience init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = false
        let textContainer = NSTextContainer()
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        self.init(frame: .zero, textContainer: textContainer)
    }

    override var canBecomeFirstResponder: Bool { false }

    func containsLink(at point: CGPoint) -> Bool {
        urlAtPoint(point) != nil
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        return containsLink(at: point)
    }

    private func urlAtPoint(_ point: CGPoint) -> URL? {
        guard let position = closestPosition(to: point) else { return nil }
        let charIndex = offset(from: beginningOfDocument, to: position)
        guard let attributed = attributedText as? NSAttributedString,
              charIndex >= 0, charIndex < attributed.length else {
            return nil
        }

        var effectiveRange = NSRange(location: 0, length: 0)
        let attributes = attributed.attributes(at: charIndex, effectiveRange: &effectiveRange)

        if let url = attributes[NSAttributedString.Key.link] as? URL {
            return url
        }
        if let urlString = attributes[NSAttributedString.Key.link] as? String {
            return URL(string: urlString)
        }
        return nil
    }
}

#Preview {
    VStack(spacing: 20) {
        LinkDetectingTextView("Check out https://convos.org for more info")

        LinkDetectingTextView("Visit www.example.com or email us at hello@example.com")

        LinkDetectingTextView("No links in this text")
    }
    .padding()
}
