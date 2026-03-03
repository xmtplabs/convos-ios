import ConvosCore
import ConvosInvitesCore
import Foundation

struct InviteURLDetectionResult {
    let code: String
    let fullURL: String
    let range: Range<String.Index>
}

enum InviteURLDetector {
    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    static func detectInviteURL(in text: String) -> InviteURLDetectionResult? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        guard let detector = linkDetector else {
            Log.error("Failed to create NSDataDetector for invite URL detection")
            return nil
        }

        guard let trimmedRange = text.range(of: trimmedText) else { return nil }

        let nsRange = NSRange(trimmedText.startIndex..., in: trimmedText)

        var foundInvite: InviteURLDetectionResult?

        detector.enumerateMatches(in: trimmedText, options: [], range: nsRange) { match, _, stop in
            guard let match = match,
                  let url = match.url,
                  let matchRange = Range(match.range, in: trimmedText) else {
                return
            }

            if let code = extractInviteCode(from: url) {
                let fullURL = url.absoluteString
                let offset = text.distance(from: text.startIndex, to: trimmedRange.lowerBound)
                let originalStart = text.index(text.startIndex, offsetBy: offset + trimmedText.distance(from: trimmedText.startIndex, to: matchRange.lowerBound))
                let originalEnd = text.index(originalStart, offsetBy: trimmedText.distance(from: matchRange.lowerBound, to: matchRange.upperBound))
                foundInvite = InviteURLDetectionResult(code: code, fullURL: fullURL, range: originalStart..<originalEnd)
                stop.pointee = true
            }
        }

        if foundInvite == nil {
            let potentialCode = trimmedText.replacingOccurrences(of: "*", with: "")
            if isLikelyInviteCode(potentialCode) {
                if (try? SignedInvite.fromURLSafeSlug(trimmedText)) != nil {
                    let fullURL = "https://\(ConfigManager.shared.associatedDomain)/i/\(trimmedText)"
                    foundInvite = InviteURLDetectionResult(code: trimmedText, fullURL: fullURL, range: trimmedRange)
                }
            }
        }

        return foundInvite
    }

    private static func extractInviteCode(from url: URL) -> String? {
        if url.scheme == "https" {
            guard let host = url.host,
                  ConfigManager.shared.associatedDomains.contains(host) else {
                return nil
            }
        } else if url.scheme != ConfigManager.shared.appUrlScheme {
            return nil
        }

        return url.convosInviteCode
    }

    static func isLikelyInviteCode(_ text: String) -> Bool {
        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_*")
        guard text.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            return false
        }

        return text.count >= Constant.minimumInviteCodeLength
    }

    static func removeInviteURL(from text: String, range: Range<String.Index>) -> String {
        var result = text
        result.removeSubrange(range)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum Constant {
        static let minimumInviteCodeLength: Int = 50
    }
}
