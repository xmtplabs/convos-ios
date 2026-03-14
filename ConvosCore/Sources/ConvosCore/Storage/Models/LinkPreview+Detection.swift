import Foundation

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

    static func isPrivateHost(_ url: URL) -> Bool {
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
