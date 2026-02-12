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
        // Create a mutable attributed string
        var result = AttributedString()

        // Use cached NSDataDetector to find URLs
        guard let detector = linkDetector else {
            return AttributedString(text)
        }

        let nsString = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

        var lastRangeEnd = 0

        for match in matches {
            guard let url = match.url else { continue }

            // Add any text before this URL as plain text
            if match.range.location > lastRangeEnd {
                let plainRange = NSRange(location: lastRangeEnd, length: match.range.location - lastRangeEnd)
                let plainText = nsString.substring(with: plainRange)
                result.append(AttributedString(plainText))
            }

            // Add the URL with link and underline attributes
            let urlText = nsString.substring(with: match.range)
            var linkString = AttributedString(urlText)
            linkString.link = url
            linkString.underlineStyle = .single
            result.append(linkString)

            lastRangeEnd = match.range.location + match.range.length
        }

        // Add any remaining text after the last URL
        if lastRangeEnd < nsString.length {
            let remainingRange = NSRange(location: lastRangeEnd, length: nsString.length - lastRangeEnd)
            let remainingText = nsString.substring(with: remainingRange)
            result.append(AttributedString(remainingText))
        }

        // If no URLs were found, return plain text
        if matches.isEmpty {
            return AttributedString(text)
        }

        return result
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
