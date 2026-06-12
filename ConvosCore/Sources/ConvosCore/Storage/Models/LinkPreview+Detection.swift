import Foundation

/// A text message split around a URL found at its start and/or end: the
/// extracted previews render as their own cells and `text` is what remains
/// in the text bubble.
public struct EdgeLinkExtraction: Hashable, Sendable {
    public let leadingPreview: LinkPreview?
    public let trailingPreview: LinkPreview?
    public let text: String

    public init(leadingPreview: LinkPreview?, trailingPreview: LinkPreview?, text: String) {
        self.leadingPreview = leadingPreview
        self.trailingPreview = trailingPreview
        self.text = text
    }
}

extension LinkPreview {
    private static let maxURLLength: Int = 2048

    public static func from(text: String) -> LinkPreview? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let url = detectSingleURL(in: trimmed) else { return nil }

        return LinkPreview(url: url.absoluteString)
    }

    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    /// Splits a URL off the start and/or end of a text message so it can
    /// render as its own link preview cell next to the remaining text.
    /// Returns nil when no edge URL is present, when the URL is the entire
    /// message (that renders as a link preview message instead), or when
    /// stripping the URLs would leave no text behind.
    public static func extractingEdgeLinks(from text: String) -> EdgeLinkExtraction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let detector = linkDetector else { return nil }

        let nsText = trimmed as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = detector.matches(in: trimmed, options: [], range: fullRange)
        guard let firstMatch = matches.first, let lastMatch = matches.last else { return nil }

        var leadingPreview: LinkPreview?
        var remainingStart = 0
        if firstMatch.range.location == 0,
           !endsInSentencePunctuation(nsText.substring(with: firstMatch.range)),
           let url = firstMatch.url,
           let resolved = validatedPreviewURL(url) {
            leadingPreview = LinkPreview(url: resolved.absoluteString)
            remainingStart = NSMaxRange(firstMatch.range)
        }

        var trailingPreview: LinkPreview?
        var remainingEnd = nsText.length
        if NSMaxRange(lastMatch.range) == nsText.length,
           lastMatch.range.location >= remainingStart,
           !endsInSentencePunctuation(nsText.substring(with: lastMatch.range)),
           let url = lastMatch.url,
           let resolved = validatedPreviewURL(url) {
            trailingPreview = LinkPreview(url: resolved.absoluteString)
            remainingEnd = lastMatch.range.location
        }

        guard leadingPreview != nil || trailingPreview != nil else { return nil }

        let remainingRange = NSRange(location: remainingStart, length: remainingEnd - remainingStart)
        let remainingText = nsText.substring(with: remainingRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainingText.isEmpty else { return nil }

        return EdgeLinkExtraction(
            leadingPreview: leadingPreview,
            trailingPreview: trailingPreview,
            text: remainingText
        )
    }

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

        return validatedPreviewURL(url)
    }

    /// The detector folds dangling sentence punctuation into a match (e.g.
    /// the "?" in "seen https://example.com?"). A matched link ending that
    /// way is prose around a link, not a link sent on its own, so it stays
    /// inline in the text bubble.
    private static func endsInSentencePunctuation(_ matchedText: String) -> Bool {
        guard let last = matchedText.last else { return true }
        return Self.sentencePunctuation.contains(last)
    }

    private static let sentencePunctuation: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "'", "\""]

    private static func validatedPreviewURL(_ url: URL) -> URL? {
        let scheme = url.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else { return nil }

        let resolved: URL
        if scheme == "http" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            resolved = components?.url ?? url
        } else {
            resolved = url
        }

        guard resolved.absoluteString.count <= maxURLLength else { return nil }
        guard !isPrivateHost(resolved) else { return nil }
        guard isStandardPort(resolved) else { return nil }

        return resolved
    }

    public static func isPrivateHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }

        if host == "localhost" || host.hasSuffix(".local") {
            return true
        }

        let stripped = host.replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        if stripped.contains(":") {
            if stripped == "::1" { return true }
            if stripped.hasPrefix("fe80") { return true }
            if stripped.hasPrefix("fc") || stripped.hasPrefix("fd") { return true }
            if stripped == "::" { return true }
            return false
        }

        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }

        if parts[0] == 127 { return true }
        if parts[0] == 10 { return true }
        if parts[0] == 172, (16 ... 31).contains(parts[1]) { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        if parts[0] == 169, parts[1] == 254 { return true }
        if parts[0] == 0 { return true }

        return false
    }

    static func isStandardPort(_ url: URL) -> Bool {
        guard let port = url.port else { return true }
        return port == 80 || port == 443
    }
}
