import SwiftUI

// MARK: - Link Detecting Text View
struct LinkDetectingTextView: View {
    let linkColor: Color?
    let isSelectable: Bool
    private let attributedText: AttributedString

    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    init(_ text: String, linkColor: Color? = nil, isSelectable: Bool = false) {
        self.linkColor = linkColor
        self.isSelectable = isSelectable
        self.attributedText = Self.makeAttributedString(from: text)
    }

    @ViewBuilder
    var body: some View {
        if isSelectable {
            Text(attributedText)
                .tint(linkColor)
                .textSelection(.enabled)
        } else {
            Text(attributedText)
                .tint(linkColor)
                .textSelection(.disabled)
        }
    }

    private static func makeAttributedString(from text: String) -> AttributedString {
        var preprocessed = text.replacingOccurrences(
            of: "(?m)^- ",
            with: "• ",
            options: .regularExpression
        )
        // Escape [ to prevent markdown link parsing ([text](url) spoofing)
        preprocessed = preprocessed.replacingOccurrences(of: "[", with: "\\[")

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let parsed = (try? AttributedString(markdown: preprocessed, options: options))
            ?? AttributedString(preprocessed)

        guard let detector = linkDetector else { return parsed }

        let plainText = String(parsed.characters)
        let nsString = plainText as NSString
        let matches = detector.matches(
            in: plainText,
            options: [],
            range: NSRange(location: 0, length: nsString.length)
        )

        guard !matches.isEmpty else { return parsed }

        // Rebuild from chunks to ensure link attributes work with SwiftUI Text
        var result = AttributedString()
        var lastEnd = parsed.startIndex

        for match in matches {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: plainText)
            else { continue }
            let startOffset = plainText.distance(from: plainText.startIndex, to: stringRange.lowerBound)
            let length = plainText.distance(from: stringRange.lowerBound, to: stringRange.upperBound)
            let attrStart = parsed.characters.index(parsed.startIndex, offsetBy: startOffset)
            let attrEnd = parsed.characters.index(attrStart, offsetBy: length)

            if lastEnd < attrStart {
                result.append(AttributedString(parsed[lastEnd ..< attrStart]))
            }

            let urlText = String(plainText[stringRange])
            var urlPortion = AttributedString(urlText)
            urlPortion.link = url
            urlPortion.underlineStyle = .single
            result.append(urlPortion)

            lastEnd = attrEnd
        }

        if lastEnd < parsed.endIndex {
            result.append(AttributedString(parsed[lastEnd ..< parsed.endIndex]))
        }

        return result
    }
}

#Preview("Links") {
    VStack(spacing: 20) {
        LinkDetectingTextView("Check out https://convos.org for more info")

        LinkDetectingTextView("Visit www.example.com or email us at hello@example.com")

        LinkDetectingTextView("No links in this text")
    }
    .padding()
}

#Preview("Markdown") {
    VStack(alignment: .leading, spacing: 20) {
        LinkDetectingTextView("This is **bold** and *italic* text")

        LinkDetectingTextView("Use ~~strikethrough~~ and `inline code`")

        LinkDetectingTextView("**Bold with a https://link.com inside**")

        LinkDetectingTextView("🎉🎉 Check https://example.com")

        LinkDetectingTextView("- First item\n- **Bold item**\n- Third item")
    }
    .padding()
}
