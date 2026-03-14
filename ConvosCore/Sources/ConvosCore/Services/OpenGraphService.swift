import Foundation

public actor OpenGraphService {
    public static let shared: OpenGraphService = OpenGraphService()

    private var cache: [String: CacheEntry] = [:]
    private var cacheOrder: [String] = []
    private var inFlightTasks: [String: Task<OpenGraphMetadata?, Never>] = [:]

    private static let maxCacheSize: Int = 100

    public struct OpenGraphMetadata: Sendable {
        public let title: String?
        public let imageURL: String?
        public let siteName: String?
    }

    private struct CacheEntry {
        let metadata: OpenGraphMetadata
    }

    private static let maxHTMLBytes: Int = 200_000
    private static let maxImageBytes: Int = 5_000_000
    private static let minImageDimension: CGFloat = 32
    private static let maxImageDimension: CGFloat = 4096

    public func fetchMetadata(for urlString: String) async -> OpenGraphMetadata? {
        if let entry = cache[urlString] {
            promoteCacheEntry(urlString)
            return entry.metadata
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

                let htmlData = data.prefix(Self.maxHTMLBytes)
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
            insertCacheEntry(urlString, metadata: result)
        }

        return result
    }

    private func insertCacheEntry(_ key: String, metadata: OpenGraphMetadata) {
        cache[key] = CacheEntry(metadata: metadata)
        cacheOrder.append(key)

        while cache.count > Self.maxCacheSize {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private func promoteCacheEntry(_ key: String) {
        if let index = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: index)
            cacheOrder.append(key)
        }
    }

    public static func isValidImageData(_ data: Data, maxBytes: Int? = nil) -> Bool {
        let limit = maxBytes ?? maxImageBytes
        guard data.count <= limit, !data.isEmpty else { return false }

        guard data.count >= 2 else { return false }
        let header = [UInt8](data.prefix(4))
        let isJPEG = header[0] == 0xFF && header[1] == 0xD8
        let isPNG = header.count >= 4 && header[0] == 0x89 && header[1] == 0x50
            && header[2] == 0x4E && header[3] == 0x47
        let isGIF = header.count >= 3 && header[0] == 0x47 && header[1] == 0x49
            && header[2] == 0x46
        let isWebP = data.count >= 12 && header.count >= 4 && header[0] == 0x52
            && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x46

        guard isJPEG || isPNG || isGIF || isWebP else { return false }

        return true
    }

    public static func isValidImageSize(width: CGFloat, height: CGFloat) -> Bool {
        width >= minImageDimension && height >= minImageDimension
            && width <= maxImageDimension && height <= maxImageDimension
    }

    func parseOpenGraphTags(from html: String) -> OpenGraphMetadata? {
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

    func decodeHTMLEntities(_ string: String) -> String {
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
                guard let hexRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result),
                      let codePoint = UInt32(result[hexRange], radix: 16),
                      let scalar = Unicode.Scalar(codePoint) else { continue }
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        let decPattern = "&#([0-9]+);"
        if let regex = try? NSRegularExpression(pattern: decPattern) {
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: nsRange).reversed()
            for match in matches {
                guard let decRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result),
                      let codePoint = UInt32(result[decRange]),
                      let scalar = Unicode.Scalar(codePoint) else { continue }
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        return result
    }
}
