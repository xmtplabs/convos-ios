import ConvosCore
import ConvosInvitesCore
import Foundation

struct InviteURLDetectionResult {
    let code: String
    let fullURL: String
    let range: Range<String.Index>
}

enum InviteURLDetector {
    /// Detects and extracts an invite URL from text
    /// Returns the invite code, full URL, and the range of the URL in the text if found
    static func detectInviteURL(in text: String) -> InviteURLDetectionResult? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        // Try to find URLs in the text
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(trimmedText.startIndex..., in: trimmedText)

        var foundInvite: InviteURLDetectionResult?

        detector?.enumerateMatches(in: trimmedText, options: [], range: range) { match, _, stop in
            guard let match = match,
                  let url = match.url,
                  let matchRange = Range(match.range, in: trimmedText) else {
                return
            }

            if let code = extractInviteCode(from: url) {
                let fullURL = url.absoluteString
                foundInvite = InviteURLDetectionResult(code: code, fullURL: fullURL, range: matchRange)
                stop.pointee = true
            }
        }

        // If no URL found via detector, check if the whole text might be an invite code
        if foundInvite == nil {
            // Check if text looks like it could be a raw invite code (base64url characters)
            let potentialCode = trimmedText.replacingOccurrences(of: "*", with: "")
            if isLikelyInviteCode(potentialCode) {
                // Verify it's actually a valid invite by trying to decode it
                if (try? SignedInvite.fromURLSafeSlug(trimmedText)) != nil {
                    let fullRange = text.startIndex..<text.endIndex
                    // Construct the full URL using the primary associated domain
                    let fullURL = "https://\(ConfigManager.shared.associatedDomain)/i/\(trimmedText)"
                    foundInvite = InviteURLDetectionResult(code: trimmedText, fullURL: fullURL, range: fullRange)
                }
            }
        }

        return foundInvite
    }

    /// Extracts invite code from a URL if it's a valid Convos invite URL
    private static func extractInviteCode(from url: URL) -> String? {
        // Check if it's a valid scheme
        if url.scheme == "https" {
            guard let host = url.host,
                  ConfigManager.shared.associatedDomains.contains(host) else {
                return nil
            }
        } else if url.scheme != ConfigManager.shared.appUrlScheme {
            return nil
        }

        // Use the existing convosInviteCode extension
        return url.convosInviteCode
    }

    /// Checks if a string looks like it could be a base64url encoded invite code
    private static func isLikelyInviteCode(_ text: String) -> Bool {
        // Invite codes are base64url encoded, so they should only contain these characters
        // Plus asterisks which are used as separators
        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_*")
        guard text.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            return false
        }

        // Invite codes are typically fairly long (compressed protobuf data)
        return text.count >= 50
    }

    /// Removes the invite URL from text, returning the cleaned text
    static func removeInviteURL(from text: String, range: Range<String.Index>) -> String {
        var result = text
        result.removeSubrange(range)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
