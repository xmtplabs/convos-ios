@testable import ConvosCore
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
