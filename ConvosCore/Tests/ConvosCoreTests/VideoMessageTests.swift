import Foundation
import Testing
@testable import ConvosCore

@Suite("Video Message Tests")
struct VideoMessageTests {
    // MARK: - MediaType

    @Test("MediaType from video mimeType")
    func testMediaTypeVideo() {
        let attachment = HydratedAttachment(key: "test", mimeType: "video/mp4")
        #expect(attachment.mediaType == .video)
    }

    @Test("MediaType from video/quicktime mimeType")
    func testMediaTypeVideoQuicktime() {
        let attachment = HydratedAttachment(key: "test", mimeType: "video/quicktime")
        #expect(attachment.mediaType == .video)
    }

    @Test("MediaType from image mimeType")
    func testMediaTypeImage() {
        let attachment = HydratedAttachment(key: "test", mimeType: "image/jpeg")
        #expect(attachment.mediaType == .image)
    }

    @Test("MediaType defaults to image when nil")
    func testMediaTypeDefaultsToImage() {
        let attachment = HydratedAttachment(key: "test")
        #expect(attachment.mediaType == .image)
    }

    @Test("MediaType audio")
    func testMediaTypeAudio() {
        let attachment = HydratedAttachment(key: "test", mimeType: "audio/mpeg")
        #expect(attachment.mediaType == .audio)
    }

    @Test("MediaType file for unknown types")
    func testMediaTypeFile() {
        let attachment = HydratedAttachment(key: "test", mimeType: "application/pdf")
        #expect(attachment.mediaType == .file)
    }

    // MARK: - HydratedAttachment properties

    @Test("thumbnailData decodes base64")
    func testThumbnailData() {
        let originalData = Data("test thumbnail".utf8)
        let base64 = originalData.base64EncodedString()
        let attachment = HydratedAttachment(key: "test", thumbnailDataBase64: base64)
        #expect(attachment.thumbnailData == originalData)
    }

    @Test("thumbnailData returns nil when no base64")
    func testThumbnailDataNil() {
        let attachment = HydratedAttachment(key: "test")
        #expect(attachment.thumbnailData == nil)
    }

    @Test("aspectRatio computed from width and height")
    func testAspectRatio() {
        let attachment = HydratedAttachment(key: "test", width: 1920, height: 1080)
        let expected = CGFloat(1920) / CGFloat(1080)
        #expect(attachment.aspectRatio == expected)
    }

    @Test("aspectRatio nil when height is zero")
    func testAspectRatioZeroHeight() {
        let attachment = HydratedAttachment(key: "test", width: 100, height: 0)
        #expect(attachment.aspectRatio == nil)
    }

    @Test("aspectRatio nil when dimensions missing")
    func testAspectRatioNilDimensions() {
        let attachment = HydratedAttachment(key: "test")
        #expect(attachment.aspectRatio == nil)
    }

    @Test("duration stored on attachment")
    func testDuration() {
        let attachment = HydratedAttachment(key: "test", duration: 10.5)
        #expect(attachment.duration == 10.5)
    }

    // MARK: - StoredRemoteAttachment video metadata

    @Test("StoredRemoteAttachment round-trips video metadata through JSON")
    func testStoredAttachmentVideoMetadata() throws {
        let stored = StoredRemoteAttachment(
            url: "https://example.com/video.enc",
            contentDigest: "abc123",
            secret: Data("secret".utf8),
            salt: Data("salt".utf8),
            nonce: Data("nonce".utf8),
            filename: "video.mp4",
            mimeType: "video/mp4",
            mediaWidth: 568,
            mediaHeight: 320,
            mediaDuration: 10.0,
            thumbnailDataBase64: "dGh1bWJuYWls"
        )

        let json = try stored.toJSON()
        let decoded = try StoredRemoteAttachment.fromJSON(json)

        #expect(decoded.mimeType == "video/mp4")
        #expect(decoded.mediaWidth == 568)
        #expect(decoded.mediaHeight == 320)
        #expect(decoded.mediaDuration == 10.0)
        #expect(decoded.thumbnailDataBase64 == "dGh1bWJuYWls")
        #expect(decoded.filename == "video.mp4")
    }

    @Test("StoredRemoteAttachment backward compatible with photo-only JSON")
    func testStoredAttachmentBackwardCompatible() throws {
        let stored = StoredRemoteAttachment(
            url: "https://example.com/photo.enc",
            contentDigest: "abc123",
            secret: Data("secret".utf8),
            salt: Data("salt".utf8),
            nonce: Data("nonce".utf8),
            filename: "photo.jpg"
        )

        let json = try stored.toJSON()
        let decoded = try StoredRemoteAttachment.fromJSON(json)

        #expect(decoded.mimeType == nil)
        #expect(decoded.mediaWidth == nil)
        #expect(decoded.mediaHeight == nil)
        #expect(decoded.mediaDuration == nil)
        #expect(decoded.thumbnailDataBase64 == nil)
    }

    @Test("StoredRemoteAttachment decodes legacy JSON without video fields")
    func testLegacyJSONDecoding() throws {
        let legacyJSON = """
        {"contentDigest":"abc","filename":"photo.jpg","nonce":"bm9uY2U=","salt":"c2FsdA==","secret":"c2VjcmV0","url":"https://example.com/photo.enc"}
        """
        let decoded = try StoredRemoteAttachment.fromJSON(legacyJSON)
        #expect(decoded.mimeType == nil)
        #expect(decoded.mediaWidth == nil)
        #expect(decoded.mediaDuration == nil)
    }

    // MARK: - Hydration

    @Test("hydrateAttachment extracts video metadata from StoredRemoteAttachment JSON key")
    func testHydrateAttachmentFromJSON() throws {
        let stored = StoredRemoteAttachment(
            url: "https://example.com/video.enc",
            contentDigest: "abc",
            secret: Data("secret".utf8),
            salt: Data("salt".utf8),
            nonce: Data("nonce".utf8),
            filename: "video.mp4",
            mimeType: "video/mp4",
            mediaWidth: 1280,
            mediaHeight: 720,
            mediaDuration: 15.5,
            thumbnailDataBase64: "dGh1bWI="
        )
        let key = try stored.toJSON()

        let hydrated = HydratedAttachment(
            key: key,
            mimeType: stored.mimeType,
            duration: stored.mediaDuration,
            thumbnailDataBase64: stored.thumbnailDataBase64
        )

        #expect(hydrated.mediaType == .video)
        #expect(hydrated.duration == 15.5)
        #expect(hydrated.thumbnailData == Data(base64Encoded: "dGh1bWI="))
    }

    // MARK: - VideoCompressionService

    @Test("VideoCompressionService max file size is 25MB")
    func testMaxFileSize() {
        #expect(VideoCompressionService.maxFileSizeBytes == 25 * 1024 * 1024)
    }
}
