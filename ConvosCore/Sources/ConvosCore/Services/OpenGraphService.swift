import Foundation

public actor OpenGraphService {
    public static let shared: OpenGraphService = OpenGraphService()

    private var cache: [String: CacheEntry] = [:]
    private var cacheOrder: [String] = []
    private var inFlightTasks: [String: Task<OpenGraphMetadata?, Never>] = [:]

    private static let maxCacheSize: Int = 100

    public struct OpenGraphMetadata: Sendable {
        public let title: String?
        public let description: String?
        public let imageURL: String?
        public let siteName: String?
        public let imageWidth: Int?
        public let imageHeight: Int?

        public init(
            title: String?,
            description: String? = nil,
            imageURL: String?,
            siteName: String?,
            imageWidth: Int?,
            imageHeight: Int?
        ) {
            self.title = title
            self.description = description
            self.imageURL = imageURL
            self.siteName = siteName
            self.imageWidth = imageWidth
            self.imageHeight = imageHeight
        }
    }

    private struct CacheEntry {
        let metadata: OpenGraphMetadata
    }

    private static let maxHTMLBytes: Int = 200_000
    private static let maxImageBytes: Int = 5_000_000
    private static let minImageDimension: CGFloat = 32
    private static let maxImageDimension: CGFloat = 4096
    private static let safeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config, delegate: SafeRedirectDelegate(), delegateQueue: nil)
    }()

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

            let ogResult = await fetchOpenGraphTags(for: url, urlString: urlString)
            if let ogResult {
                return ogResult
            }

            if LinkPreview.socialPlatform(for: urlString) == .twitter {
                return await fetchTwitterMetadata(for: url)
            }

            if let provider = RichLinkMetadata.provider {
                return await provider.fetchMetadata(for: url)
            }

            return nil
        }

        inFlightTasks[urlString] = task
        let result = await task.value
        inFlightTasks[urlString] = nil

        if let result {
            insertCacheEntry(urlString, metadata: result)
        }

        return result
    }

    private func fetchOpenGraphTags(for url: URL, urlString: String) async -> OpenGraphMetadata? {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            request.setValue(
                "facebookexternalhit/1.1 (compatible; Convos/1.0)",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("text/html", forHTTPHeaderField: "Accept")

            let (data, response) = try await Self.safeSession.data(for: request)

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
            && data[8] == 0x57 && data[9] == 0x45 && data[10] == 0x42 && data[11] == 0x50

        guard isJPEG || isPNG || isGIF || isWebP else { return false }

        return true
    }

    public static func isValidImageSize(width: CGFloat, height: CGFloat) -> Bool {
        width >= minImageDimension && height >= minImageDimension
            && width <= maxImageDimension && height <= maxImageDimension
    }

    public func loadImage(from url: URL) async -> ImageType? {
        do {
            let (data, _) = try await Self.safeSession.data(from: url)
            guard Self.isValidImageData(data) else { return nil }
            guard let image = ImageType(data: data),
                  Self.isValidImageSize(width: image.size.width, height: image.size.height)
            else { return nil }
            return image
        } catch {
            return nil
        }
    }

    private func fetchTwitterMetadata(for url: URL) async -> OpenGraphMetadata? {
        async let oembedResult = fetchTwitterOEmbed(for: url)
        async let lpResult: OpenGraphMetadata? = RichLinkMetadata.provider?.fetchMetadata(for: url)

        let oembed = await oembedResult
        let lp = await lpResult

        guard oembed != nil || lp != nil else { return nil }

        return OpenGraphMetadata(
            title: lp?.title,
            description: oembed?.tweetText ?? lp?.description,
            imageURL: lp?.imageURL,
            siteName: oembed?.authorName ?? lp?.siteName,
            imageWidth: lp?.imageWidth,
            imageHeight: lp?.imageHeight
        )
    }

    struct OEmbedResult {
        let tweetText: String
        let authorName: String?
    }

    func fetchTwitterOEmbed(for url: URL) async -> OEmbedResult? {
        guard let oembedURL = URL(
            string: "https://publish.twitter.com/oembed?url=\(url.absoluteString)&omit_script=true"
        ) else { return nil }

        do {
            var request = URLRequest(url: oembedURL)
            request.timeoutInterval = 8
            let (data, response) = try await Self.safeSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ... 299).contains(httpResponse.statusCode) else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let html = json["html"] as? String else { return nil }

            guard let tweetText = parseTweetText(from: html), !tweetText.isEmpty else { return nil }

            let authorName = json["author_name"] as? String
            return OEmbedResult(tweetText: tweetText, authorName: authorName)
        } catch {
            return nil
        }
    }

    func parseTweetText(from oembedHTML: String) -> String? {
        let pPattern = "<p[^>]*>(.*?)</p>"
        guard let regex = try? NSRegularExpression(pattern: pPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: oembedHTML, range: NSRange(oembedHTML.startIndex..., in: oembedHTML)),
              let range = Range(match.range(at: 1), in: oembedHTML) else {
            return nil
        }

        var text = String(oembedHTML[range])
        text = stripHTMLTags(text)
        text = decodeHTMLEntities(text)
        text = cleanTweetText(text)
        return text.isEmpty ? nil : text
    }

    private func stripHTMLTags(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return html }
        return regex.stringByReplacingMatches(
            in: html,
            range: NSRange(html.startIndex..., in: html),
            withTemplate: ""
        )
    }

    private func cleanTweetText(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "\\s*pic\\.twitter\\.com/\\S+") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        if let regex = try? NSRegularExpression(pattern: "\\s*https?://t\\.co/\\S+") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let maxHeadBytes: Int = 50_000

    private func extractHead(from html: String) -> String {
        if let endRange = html.range(of: "</head>", options: .caseInsensitive) {
            return String(html[html.startIndex ..< endRange.upperBound])
        }
        return String(html.prefix(Self.maxHeadBytes))
    }

    func parseOpenGraphTags(from html: String) -> OpenGraphMetadata? {
        let head = extractHead(from: html)
        let title = extractMetaContent(property: "og:title", from: head)
            ?? extractHTMLTitle(from: head)
        let description = extractMetaContent(property: "og:description", from: head)
        let imageURL = extractMetaContent(property: "og:image", from: head)
        let siteName = extractMetaContent(property: "og:site_name", from: head)
        let imageWidth = extractMetaContent(property: "og:image:width", from: head).flatMap { Int($0) }
        let imageHeight = extractMetaContent(property: "og:image:height", from: head).flatMap { Int($0) }

        guard title != nil || imageURL != nil else { return nil }

        return OpenGraphMetadata(
            title: title,
            description: description,
            imageURL: imageURL,
            siteName: siteName,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
    }

    private func extractMetaContent(property: String, from html: String) -> String? {
        let patterns = [
            "<meta[^>]+property=\"\(property)\"[^>]+content=\"([^\"]*)\"",
            "<meta[^>]+property='\(property)'[^>]+content='([^']*)'",
            "<meta[^>]+content=\"([^\"]*)\"[^>]+property=\"\(property)\"",
            "<meta[^>]+content='([^']*)'[^>]+property='\(property)'",
            "<meta[^>]+name=\"\(property)\"[^>]+content=\"([^\"]*)\"",
            "<meta[^>]+name='\(property)'[^>]+content='([^']*)'",
            "<meta[^>]+content=\"([^\"]*)\"[^>]+name=\"\(property)\"",
            "<meta[^>]+content='([^']*)'[^>]+name='\(property)'",
        ]

        let nsRange = NSRange(html.startIndex..., in: html)
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: nsRange),
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

private final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url, LinkPreview.isPrivateHost(url) {
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }
}
