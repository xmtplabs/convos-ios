#if canImport(UIKit)
import Foundation

@MainActor
public final class HTMLPageMetadata {
    public static let shared: HTMLPageMetadata = HTMLPageMetadata()

    private var titleCache: [String: String] = [:]
    private var inflight: [String: Task<String?, Never>] = [:]

    public func cachedTitle(for attachmentKey: String) -> String? {
        titleCache[attachmentKey]
    }

    public func title(for attachmentKey: String, fileURL: URL) async -> String? {
        if let cached = titleCache[attachmentKey] { return cached }
        if let existing = inflight[attachmentKey] { return await existing.value }

        let task = Task<String?, Never> {
            await Self.extractTitle(from: fileURL)
        }
        inflight[attachmentKey] = task
        let title = await task.value
        inflight.removeValue(forKey: attachmentKey)
        if let title {
            titleCache[attachmentKey] = title
        }
        return title
    }

    private nonisolated static func extractTitle(from url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }
            let pattern = #"<title[^>]*>([\s\S]*?)</title>"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                return nil
            }
            let range = NSRange(html.startIndex..., in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  match.numberOfRanges >= 2,
                  let captured = Range(match.range(at: 1), in: html) else {
                return nil
            }
            let raw = String(html[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { return nil }
            return Self.decodeEntities(raw)
        }.value
    }

    /// Both the decimal and hex numeric forms are decoded, because the two
    /// producers disagree: HTML written by hand tends to use `&#39;`, while
    /// Python's `html.escape` — which the runtime runs over every artifact
    /// title — emits `&#x27;`. Decoding only one leaves titles like
    /// "Who&#x27;s here" on screen, which is what the group sees for any
    /// artifact whose title contains an apostrophe.
    private nonisolated static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&#x3C;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#x3E;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#x22;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            // Ampersand last: decoding it first would turn an escaped literal
            // like `&amp;#x27;` into `&#x27;` and then into an apostrophe.
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
#endif
