@testable import ConvosCore
import Foundation
import Testing

@Suite("LinkPreview Detection")
struct LinkPreviewDetectionTests {
    @Test("Detects standalone HTTPS URL")
    func standaloneHTTPS() {
        let preview = LinkPreview.from(text: "https://www.apple.com")
        #expect(preview != nil)
        #expect(preview?.url == "https://www.apple.com")
    }

    @Test("Detects standalone HTTP URL and upgrades to HTTPS")
    func httpUpgradedToHTTPS() {
        let preview = LinkPreview.from(text: "http://example.com")
        #expect(preview != nil)
        #expect(preview?.url == "https://example.com")
    }

    @Test("Detects bare domain and normalizes to HTTPS")
    func bareDomain() {
        let preview = LinkPreview.from(text: "xmtp.com")
        #expect(preview != nil)
        #expect(preview?.url.hasPrefix("https://") == true)
    }

    @Test("Rejects URL mixed with text")
    func urlWithSurroundingText() {
        let preview = LinkPreview.from(text: "Check out https://example.com for details")
        #expect(preview == nil)
    }

    @Test("Rejects multiple URLs")
    func multipleURLs() {
        let preview = LinkPreview.from(text: "https://apple.com https://google.com")
        #expect(preview == nil)
    }

    @Test("Rejects empty string")
    func emptyString() {
        let preview = LinkPreview.from(text: "")
        #expect(preview == nil)
    }

    @Test("Rejects whitespace-only string")
    func whitespaceOnly() {
        let preview = LinkPreview.from(text: "   ")
        #expect(preview == nil)
    }

    @Test("Rejects plain text without URL")
    func plainText() {
        let preview = LinkPreview.from(text: "Hello world")
        #expect(preview == nil)
    }

    @Test("Rejects non-HTTP scheme")
    func nonHTTPScheme() {
        let preview = LinkPreview.from(text: "ftp://files.example.com/data")
        #expect(preview == nil)
    }

    @Test("Trims whitespace around URL")
    func whitespaceAroundURL() {
        let preview = LinkPreview.from(text: "  https://example.com  ")
        #expect(preview != nil)
        #expect(preview?.url == "https://example.com")
    }

    @Test("Detects URL with path")
    func urlWithPath() {
        let preview = LinkPreview.from(text: "https://example.com/article/123")
        #expect(preview != nil)
        #expect(preview?.url == "https://example.com/article/123")
    }

    @Test("Detects URL with query parameters")
    func urlWithQuery() {
        let preview = LinkPreview.from(text: "https://example.com/search?q=test&page=1")
        #expect(preview != nil)
    }

    @Test("displayHost returns host")
    func displayHost() {
        let preview = LinkPreview(url: "https://www.example.com/page")
        #expect(preview.displayHost == "www.example.com")
    }

    @Test("resolvedURL returns valid URL")
    func resolvedURL() {
        let preview = LinkPreview(url: "https://example.com")
        #expect(preview.resolvedURL != nil)
        #expect(preview.resolvedURL?.absoluteString == "https://example.com")
    }

    @Test("Rejects localhost")
    func rejectsLocalhost() {
        let preview = LinkPreview.from(text: "https://localhost/admin")
        #expect(preview == nil)
    }

    @Test("Rejects private IP 10.x.x.x")
    func rejectsPrivateIP10() {
        let preview = LinkPreview.from(text: "https://10.0.0.1/secret")
        #expect(preview == nil)
    }

    @Test("Rejects private IP 192.168.x.x")
    func rejectsPrivateIP192() {
        let preview = LinkPreview.from(text: "https://192.168.1.1")
        #expect(preview == nil)
    }

    @Test("Rejects private IP 172.16.x.x")
    func rejectsPrivateIP172() {
        let preview = LinkPreview.from(text: "https://172.16.0.1")
        #expect(preview == nil)
    }

    @Test("Rejects loopback 127.x.x.x")
    func rejectsLoopback() {
        let preview = LinkPreview.from(text: "https://127.0.0.1:8080/api")
        #expect(preview == nil)
    }

    @Test("Rejects non-standard port")
    func rejectsNonStandardPort() {
        let preview = LinkPreview.from(text: "https://example.com:8443/page")
        #expect(preview == nil)
    }

    @Test("Allows standard port 443")
    func allowsStandardPort443() {
        let preview = LinkPreview.from(text: "https://example.com:443/page")
        #expect(preview != nil)
    }

    @Test("Rejects URL exceeding max length")
    func rejectsLongURL() {
        let longPath = String(repeating: "a", count: 2100)
        let preview = LinkPreview.from(text: "https://example.com/\(longPath)")
        #expect(preview == nil)
    }

    @Test("Rejects .local domains")
    func rejectsLocalDomain() {
        let preview = LinkPreview.from(text: "https://myserver.local/dashboard")
        #expect(preview == nil)
    }

    @Test("Rejects IPv6 loopback")
    func rejectsIPv6Loopback() {
        let url = URL(string: "https://[::1]/admin")!
        #expect(LinkPreview.isPrivateHost(url))
    }

    @Test("Rejects IPv6 link-local")
    func rejectsIPv6LinkLocal() {
        let url = URL(string: "https://[fe80::1]/page")!
        #expect(LinkPreview.isPrivateHost(url))
    }

    @Test("Rejects IPv6 unique local (fc/fd)")
    func rejectsIPv6UniqueLocal() {
        let url = URL(string: "https://[fd12:3456::1]/page")!
        #expect(LinkPreview.isPrivateHost(url))
    }

    @Test("Allows public IPv6")
    func allowsPublicIPv6() {
        let url = URL(string: "https://[2607:f8b0:4004:800::200e]/")!
        #expect(!LinkPreview.isPrivateHost(url))
    }
}

@Suite("OpenGraph Parsing")
struct OpenGraphParsingTests {
    let service: OpenGraphService = OpenGraphService()

    @Test("Parses og:title and og:image")
    func parsesOGTags() async {
        let html = """
        <html><head>
        <meta property="og:title" content="Test Title">
        <meta property="og:image" content="https://example.com/image.jpg">
        <meta property="og:site_name" content="Example">
        </head></html>
        """
        let metadata = await service.parseOpenGraphTags(from: html)
        #expect(metadata != nil)
        #expect(metadata?.title == "Test Title")
        #expect(metadata?.imageURL == "https://example.com/image.jpg")
        #expect(metadata?.siteName == "Example")
    }

    @Test("Falls back to title tag when no og:title")
    func fallsBackToHTMLTitle() async {
        let html = """
        <html><head>
        <title>Fallback Title</title>
        <meta property="og:image" content="https://example.com/image.jpg">
        </head></html>
        """
        let metadata = await service.parseOpenGraphTags(from: html)
        #expect(metadata != nil)
        #expect(metadata?.title == "Fallback Title")
    }

    @Test("Returns nil when no OG tags or title")
    func returnsNilForNoTags() async {
        let html = "<html><head></head><body>Hello</body></html>"
        let metadata = await service.parseOpenGraphTags(from: html)
        #expect(metadata == nil)
    }

    @Test("Handles content-before-property attribute order")
    func contentBeforeProperty() async {
        let html = """
        <html><head>
        <meta content="Reversed Order" property="og:title">
        </head></html>
        """
        let metadata = await service.parseOpenGraphTags(from: html)
        #expect(metadata != nil)
        #expect(metadata?.title == "Reversed Order")
    }

    @Test("Handles name attribute instead of property")
    func nameAttribute() async {
        let html = """
        <html><head>
        <meta name="og:title" content="Name Attr Title">
        <meta name="og:image" content="https://example.com/img.png">
        </head></html>
        """
        let metadata = await service.parseOpenGraphTags(from: html)
        #expect(metadata != nil)
        #expect(metadata?.title == "Name Attr Title")
    }

    @Test("Case-insensitive tag matching")
    func caseInsensitive() async {
        let html = """
        <html><head>
        <META PROPERTY="og:title" CONTENT="Upper Case">
        <META PROPERTY="og:image" CONTENT="https://example.com/img.jpg">
        </head></html>
        """
        let metadata = await service.parseOpenGraphTags(from: html)
        #expect(metadata != nil)
        #expect(metadata?.title == "Upper Case")
    }

    @Test("Returns metadata with only og:image (no title)")
    func imageOnly() async {
        let html = """
        <html><head>
        <meta property="og:image" content="https://example.com/photo.jpg">
        </head></html>
        """
        let metadata = await service.parseOpenGraphTags(from: html)
        #expect(metadata != nil)
        #expect(metadata?.title == nil)
        #expect(metadata?.imageURL == "https://example.com/photo.jpg")
    }
}

@Suite("HTML Entity Decoding")
struct HTMLEntityDecodingTests {
    let service: OpenGraphService = OpenGraphService()

    @Test("Decodes named entities")
    func namedEntities() async {
        let result = await service.decodeHTMLEntities("Tom &amp; Jerry")
        #expect(result == "Tom & Jerry")
    }

    @Test("Decodes &lt; and &gt;")
    func ltGtEntities() async {
        let result = await service.decodeHTMLEntities("a &lt; b &gt; c")
        #expect(result == "a < b > c")
    }

    @Test("Decodes &quot; and &apos;")
    func quotEntities() async {
        let result = await service.decodeHTMLEntities("&quot;hello&quot; &apos;world&apos;")
        #expect(result == "\"hello\" 'world'")
    }

    @Test("Decodes &#39; numeric entity")
    func numericApostrophe() async {
        let result = await service.decodeHTMLEntities("it&#39;s")
        #expect(result == "it's")
    }

    @Test("Decodes hex entities")
    func hexEntities() async {
        let result = await service.decodeHTMLEntities("world&#x27;s best")
        #expect(result == "world's best")
    }

    @Test("Decodes decimal entities")
    func decimalEntities() async {
        let result = await service.decodeHTMLEntities("&#169; 2026")
        #expect(result == "© 2026")
    }

    @Test("Decodes &nbsp;")
    func nbspEntity() async {
        let result = await service.decodeHTMLEntities("hello&nbsp;world")
        #expect(result == "hello world")
    }

    @Test("Handles string with no entities")
    func noEntities() async {
        let result = await service.decodeHTMLEntities("plain text")
        #expect(result == "plain text")
    }

    @Test("Handles multiple mixed entities")
    func mixedEntities() async {
        let result = await service.decodeHTMLEntities("&lt;div&gt;Tom &amp; Jerry&#x27;s &quot;show&quot;&lt;/div&gt;")
        #expect(result == "<div>Tom & Jerry's \"show\"</div>")
    }
}

@Suite("Image Validation")
struct ImageValidationTests {
    @Test("Accepts JPEG data")
    func acceptsJPEG() {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        data.append(Data(repeating: 0x00, count: 100))
        #expect(OpenGraphService.isValidImageData(data))
    }

    @Test("Accepts PNG data")
    func acceptsPNG() {
        var data = Data([0x89, 0x50, 0x4E, 0x47])
        data.append(Data(repeating: 0x00, count: 100))
        #expect(OpenGraphService.isValidImageData(data))
    }

    @Test("Accepts GIF data")
    func acceptsGIF() {
        var data = Data([0x47, 0x49, 0x46, 0x38])
        data.append(Data(repeating: 0x00, count: 100))
        #expect(OpenGraphService.isValidImageData(data))
    }

    @Test("Rejects empty data")
    func rejectsEmpty() {
        #expect(!OpenGraphService.isValidImageData(Data()))
    }

    @Test("Rejects non-image data")
    func rejectsNonImage() {
        let data = Data("<!DOCTYPE html>".utf8)
        #expect(!OpenGraphService.isValidImageData(data))
    }

    @Test("Rejects oversized data")
    func rejectsOversized() {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        data.append(Data(repeating: 0x00, count: 6_000_000))
        #expect(!OpenGraphService.isValidImageData(data))
    }

    @Test("Valid image dimensions")
    func validDimensions() {
        #expect(OpenGraphService.isValidImageSize(width: 1200, height: 630))
        #expect(OpenGraphService.isValidImageSize(width: 32, height: 32))
    }

    @Test("Rejects tiny image dimensions")
    func rejectsTinyDimensions() {
        #expect(!OpenGraphService.isValidImageSize(width: 1, height: 1))
        #expect(!OpenGraphService.isValidImageSize(width: 10, height: 10))
    }

    @Test("Rejects oversized dimensions")
    func rejectsOversizedDimensions() {
        #expect(!OpenGraphService.isValidImageSize(width: 10000, height: 10000))
    }
}

@Suite("Rich Link Metadata Fallback")
struct RichLinkMetadataFallbackTests {
    @Test("Provider is nil by default")
    func providerNilByDefault() {
        RichLinkMetadata.resetForTesting()
        #expect(RichLinkMetadata.provider == nil)
    }

    @Test("Provider can be configured")
    func providerCanBeConfigured() {
        RichLinkMetadata.resetForTesting()
        let mock = MockRichLinkProvider(result: nil)
        RichLinkMetadata.configure(mock)
        #expect(RichLinkMetadata.provider != nil)
        RichLinkMetadata.resetForTesting()
    }

    @Test("Provider can be reset for testing")
    func providerResetForTesting() {
        RichLinkMetadata.resetForTesting()
        let mock = MockRichLinkProvider(result: nil)
        RichLinkMetadata.configure(mock)
        #expect(RichLinkMetadata.provider != nil)
        RichLinkMetadata.resetForTesting()
        #expect(RichLinkMetadata.provider == nil)
    }
}

private struct MockRichLinkProvider: RichLinkMetadataProviding {
    let result: OpenGraphService.OpenGraphMetadata?

    func fetchMetadata(for url: URL) async -> OpenGraphService.OpenGraphMetadata? {
        result
    }
}

@Suite("Social Platform Detection")
struct SocialPlatformDetectionTests {
    @Test("Detects x.com as twitter")
    func detectsXCom() {
        let preview = LinkPreview(url: "https://x.com/elonmusk/status/123456")
        #expect(preview.socialPlatform == .twitter)
    }

    @Test("Detects twitter.com as twitter")
    func detectsTwitterCom() {
        let preview = LinkPreview(url: "https://twitter.com/jack/status/789")
        #expect(preview.socialPlatform == .twitter)
    }

    @Test("Detects www.x.com as twitter")
    func detectsWwwXCom() {
        let preview = LinkPreview(url: "https://www.x.com/user/status/123")
        #expect(preview.socialPlatform == .twitter)
    }

    @Test("Detects threads.net as threads")
    func detectsThreads() {
        let preview = LinkPreview(url: "https://www.threads.net/@zuck/post/abc123")
        #expect(preview.socialPlatform == .threads)
    }

    @Test("Detects bsky.app as bluesky")
    func detectsBluesky() {
        let preview = LinkPreview(url: "https://bsky.app/profile/jay.bsky.social/post/xyz")
        #expect(preview.socialPlatform == .bluesky)
    }

    @Test("Returns nil for non-social domains")
    func returnsNilForNonSocial() {
        let preview = LinkPreview(url: "https://example.com/article")
        #expect(preview.socialPlatform == nil)
    }

    @Test("Returns nil for invalid URL")
    func returnsNilForInvalidURL() {
        let preview = LinkPreview(url: "not a url")
        #expect(preview.socialPlatform == nil)
    }
}

@Suite("Social Username Extraction")
struct SocialUsernameExtractionTests {
    @Test("Extracts twitter username from status URL")
    func extractsTwitterUsername() {
        let preview = LinkPreview(url: "https://x.com/elonmusk/status/123456")
        #expect(preview.socialUsername == "elonmusk")
    }

    @Test("Returns nil for twitter homepage")
    func returnsNilForTwitterHomepage() {
        let preview = LinkPreview(url: "https://x.com")
        #expect(preview.socialUsername == nil)
    }

    @Test("Returns nil for twitter profile without status")
    func returnsNilForTwitterProfile() {
        let preview = LinkPreview(url: "https://x.com/elonmusk")
        #expect(preview.socialUsername == nil)
    }

    @Test("Extracts threads username and strips @")
    func extractsThreadsUsername() {
        let preview = LinkPreview(url: "https://www.threads.net/@zuck/post/abc123")
        #expect(preview.socialUsername == "zuck")
    }

    @Test("Extracts threads username without @")
    func extractsThreadsUsernameNoAt() {
        let preview = LinkPreview(url: "https://threads.net/zuck/post/abc123")
        #expect(preview.socialUsername == "zuck")
    }

    @Test("Extracts bluesky handle")
    func extractsBlueskyHandle() {
        let preview = LinkPreview(url: "https://bsky.app/profile/jay.bsky.social/post/xyz")
        #expect(preview.socialUsername == "jay.bsky.social")
    }

    @Test("Returns nil for bluesky homepage")
    func returnsNilForBlueskyHomepage() {
        let preview = LinkPreview(url: "https://bsky.app")
        #expect(preview.socialUsername == nil)
    }

    @Test("Returns nil for bluesky non-profile path")
    func returnsNilForBlueskyNonProfile() {
        let preview = LinkPreview(url: "https://bsky.app/about")
        #expect(preview.socialUsername == nil)
    }
}

@Suite("OpenGraph Description Parsing")
struct OpenGraphDescriptionParsingTests {
    let service: OpenGraphService = .init()

    @Test("Parses og:description")
    func parsesDescription() async {
        let html = """
        <html><head>
        <meta property="og:title" content="Test Title">
        <meta property="og:description" content="A test description">
        </head></html>
        """
        let result = await service.parseOpenGraphTags(from: html)
        #expect(result?.description == "A test description")
    }

    @Test("Returns nil description when not present")
    func returnsNilDescriptionWhenMissing() async {
        let html = """
        <html><head>
        <meta property="og:title" content="Test Title">
        </head></html>
        """
        let result = await service.parseOpenGraphTags(from: html)
        #expect(result?.description == nil)
    }

    @Test("Decodes HTML entities in description")
    func decodesEntitiesInDescription() async {
        let html = """
        <html><head>
        <meta property="og:title" content="Test">
        <meta property="og:description" content="It&apos;s a &quot;test&quot; &amp; more">
        </head></html>
        """
        let result = await service.parseOpenGraphTags(from: html)
        #expect(result?.description == "It's a \"test\" & more")
    }
}

@Suite("Twitter oEmbed Parsing")
struct TwitterOEmbedParsingTests {
    let service: OpenGraphService = .init()

    @Test("Extracts plain text from oEmbed HTML")
    func extractsPlainText() async {
        let html = """
        <blockquote class="twitter-tweet"><p lang="en" dir="ltr">just setting up my twttr</p>\
        &mdash; jack (@jack)</blockquote>
        """
        let result = await service.parseTweetText(from: html)
        #expect(result == "just setting up my twttr")
    }

    @Test("Strips anchor tags but keeps text content")
    func stripsAnchorsKeepsText() async {
        let html = """
        <blockquote class="twitter-tweet"><p lang="en" dir="ltr">Hello \
        <a href="https://twitter.com/convos">@convos</a> world</p></blockquote>
        """
        let result = await service.parseTweetText(from: html)
        #expect(result == "Hello @convos world")
    }

    @Test("Decodes HTML entities")
    func decodesEntities() async {
        let html = """
        <blockquote><p lang="en" dir="ltr">It&apos;s a &quot;test&quot; &amp; more</p></blockquote>
        """
        let result = await service.parseTweetText(from: html)
        #expect(result == "It's a \"test\" & more")
    }

    @Test("Strips pic.twitter.com references")
    func stripsPicTwitter() async {
        let html = """
        <blockquote><p lang="en" dir="ltr">Check this out pic.twitter.com/abc123</p></blockquote>
        """
        let result = await service.parseTweetText(from: html)
        #expect(result == "Check this out")
    }

    @Test("Strips trailing t.co links")
    func stripsTcoLinks() async {
        let html = """
        <blockquote><p lang="en" dir="ltr">Read more \
        <a href="https://t.co/abc">https://t.co/abc</a></p></blockquote>
        """
        let result = await service.parseTweetText(from: html)
        #expect(result == "Read more")
    }

    @Test("Returns nil for empty paragraph")
    func returnsNilForEmpty() async {
        let html = "<blockquote><p></p></blockquote>"
        let result = await service.parseTweetText(from: html)
        #expect(result == nil)
    }

    @Test("Returns nil for malformed HTML")
    func returnsNilForMalformed() async {
        let result = await service.parseTweetText(from: "not html at all")
        #expect(result == nil)
    }

    @Test("Handles tweet with only media references")
    func handlesMediaOnlyTweet() async {
        let html = """
        <blockquote><p lang="en" dir="ltr">\
        <a href="https://t.co/xyz">pic.twitter.com/xyz</a></p></blockquote>
        """
        let result = await service.parseTweetText(from: html)
        #expect(result == nil)
    }
}

@Suite("Static Social Platform Detection")
struct StaticSocialPlatformDetectionTests {
    @Test("Detects twitter from x.com URL string")
    func detectsTwitter() {
        #expect(LinkPreview.socialPlatform(for: "https://x.com/user/status/123") == .twitter)
    }

    @Test("Detects twitter from twitter.com URL string")
    func detectsTwitterLegacy() {
        #expect(LinkPreview.socialPlatform(for: "https://twitter.com/user/status/123") == .twitter)
    }

    @Test("Detects threads from URL string")
    func detectsThreads() {
        #expect(LinkPreview.socialPlatform(for: "https://threads.net/@user/post/abc") == .threads)
    }

    @Test("Returns nil for non-social URL string")
    func returnsNilForNonSocial() {
        #expect(LinkPreview.socialPlatform(for: "https://example.com") == nil)
    }

    @Test("Returns nil for invalid URL string")
    func returnsNilForInvalid() {
        #expect(LinkPreview.socialPlatform(for: "not a url") == nil)
    }
}

@Suite("LinkPreview Description Codable")
struct LinkPreviewDescriptionCodableTests {
    @Test("Decodes JSON without description field")
    func decodesWithoutDescription() throws {
        let json = """
        {"url":"https://example.com","title":"Test"}
        """
        let data = Data(json.utf8)
        let preview = try JSONDecoder().decode(LinkPreview.self, from: data)
        #expect(preview.url == "https://example.com")
        #expect(preview.title == "Test")
        #expect(preview.description == nil)
    }

    @Test("Round-trips description through JSON")
    func roundTripsDescription() throws {
        let preview = LinkPreview(
            url: "https://example.com",
            title: "Test",
            description: "A description"
        )
        let data = try JSONEncoder().encode(preview)
        let decoded = try JSONDecoder().decode(LinkPreview.self, from: data)
        #expect(decoded.description == "A description")
    }
}
