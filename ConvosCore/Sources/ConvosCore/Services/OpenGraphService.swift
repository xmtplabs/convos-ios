import Foundation

public actor OpenGraphService {
    public static let shared: OpenGraphService = OpenGraphService()

    private var cache: [String: OpenGraphMetadata] = [:]
    private var inFlightTasks: [String: Task<OpenGraphMetadata?, Never>] = [:]

    public struct OpenGraphMetadata: Sendable {
        public let title: String?
        public let imageURL: String?
        public let siteName: String?
    }

    public func fetchMetadata(for urlString: String) async -> OpenGraphMetadata? {
        if let cached = cache[urlString] {
            return cached
        }

        if let existing = inFlightTasks[urlString] {
            return await existing.value
        }

        let task = Task<OpenGraphMetadata?, Never> {
            guard let url = URL(string: urlString) else { return nil }

            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 8
                request.setValue(
                    "facebookexternalhit/1.1 (compatible; Convos/1.0)",
                    forHTTPHeaderField: "User-Agent"
                )
                request.setValue("text/html", forHTTPHeaderField: "Accept")

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      (200 ... 299).contains(httpResponse.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    Log.error("OpenGraph fetch failed for \(urlString): HTTP \(code)")
                    return nil
                }

                let maxBytes = 200_000
                let htmlData = data.prefix(maxBytes)
                guard let html = String(data: htmlData, encoding: .utf8)
                        ?? String(data: htmlData, encoding: .ascii) else {
                    Log.error("OpenGraph decode failed for \(urlString): not UTF-8/ASCII")
                    return nil
                }

                let result = parseOpenGraphTags(from: html)
                if result == nil {
                    Log.warning("OpenGraph no tags found for \(urlString) (\(data.count) bytes)")
                }
                return result
            } catch {
                Log.error("OpenGraph fetch error for \(urlString): \(error.localizedDescription)")
                return nil
            }
        }

        inFlightTasks[urlString] = task
        let result = await task.value
        inFlightTasks[urlString] = nil

        if let result {
            cache[urlString] = result
        }

        return result
    }

    private func parseOpenGraphTags(from html: String) -> OpenGraphMetadata? {
        let title = extractMetaContent(property: "og:title", from: html)
            ?? extractHTMLTitle(from: html)
        let imageURL = extractMetaContent(property: "og:image", from: html)
        let siteName = extractMetaContent(property: "og:site_name", from: html)

        guard title != nil || imageURL != nil else { return nil }

        return OpenGraphMetadata(
            title: title,
            imageURL: imageURL,
            siteName: siteName
        )
    }

    private func extractMetaContent(property: String, from html: String) -> String? {
        let patterns = [
            "<meta[^>]+property=[\"']\(property)[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']\(property)[\"']",
            "<meta[^>]+name=[\"']\(property)[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+name=[\"']\(property)[\"']",
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let value = decodeHTMLEntities(String(html[range]))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private func extractHTMLTitle(from html: String) -> String? {
        let pattern = "<title[^>]*>([^<]+)</title>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let title = decodeHTMLEntities(String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines))
        return title.isEmpty ? nil : title
    }

    private func decodeHTMLEntities(_ string: String) -> String {
        var result = string
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        let hexPattern = "&#x([0-9a-fA-F]+);"
        if let regex = try? NSRegularExpression(pattern: hexPattern) {
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: nsRange).reversed()
            for match in matches {
                if let hexRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[hexRange], radix: 16),
                   let scalar = Unicode.Scalar(codePoint) {
                    let fullRange = Range(match.range, in: result)!
                    result.replaceSubrange(fullRange, with: String(Character(scalar)))
                }
            }
        }

        let decPattern = "&#([0-9]+);"
        if let regex = try? NSRegularExpression(pattern: decPattern) {
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: nsRange).reversed()
            for match in matches {
                if let decRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[decRange]),
                   let scalar = Unicode.Scalar(codePoint) {
                    let fullRange = Range(match.range, in: result)!
                    result.replaceSubrange(fullRange, with: String(Character(scalar)))
                }
            }
        }

        return result
    }
}
