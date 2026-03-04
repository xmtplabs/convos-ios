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

        let nsRange = NSRange(text.startIndex..., in: text)

        var foundInvite: InviteURLDetectionResult?

        detector.enumerateMatches(in: text, options: [], range: nsRange) { match, _, stop in
            guard let match = match,
                  let url = match.url,
                  let matchRange = Range(match.range, in: text) else {
                return
            }

            if let code = extractInviteCode(from: url) {
                foundInvite = InviteURLDetectionResult(code: code, fullURL: url.absoluteString, range: matchRange)
                stop.pointee = true
            }
        }

        if foundInvite == nil {
            let potentialCode = trimmedText.replacingOccurrences(of: "*", with: "")
            if isLikelyInviteCode(potentialCode),
               (try? SignedInvite.fromURLSafeSlug(potentialCode)) != nil {
                let fullURL = "https://\(ConfigManager.shared.associatedDomain)/i/\(potentialCode)"
                foundInvite = InviteURLDetectionResult(code: potentialCode, fullURL: fullURL, range: text.startIndex..<text.endIndex)
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
