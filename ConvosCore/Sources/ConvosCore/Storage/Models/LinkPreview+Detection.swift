import Foundation

extension LinkPreview {
    public static func from(text: String) -> LinkPreview? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let url = detectSingleURL(in: trimmed) else { return nil }

        return LinkPreview(url: url.absoluteString)
    }

    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static func detectSingleURL(in text: String) -> URL? {
        guard let detector = linkDetector else { return nil }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: nsRange)

        guard matches.count == 1,
              let match = matches.first,
              let matchRange = Range(match.range, in: text),
              let url = match.url else {
            return nil
        }

        let matchedText = text[matchRange].trimmingCharacters(in: .whitespacesAndNewlines)
        let fullText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matchedText == fullText else { return nil }

        let scheme = url.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else { return nil }

        if scheme == "http" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            return components?.url ?? url
        }

        return url
    }
}
