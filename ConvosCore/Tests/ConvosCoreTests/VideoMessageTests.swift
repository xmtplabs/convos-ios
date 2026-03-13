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

    // MARK: - Attachments Preview String

    @Test("Single photo attachment shows 'a photo'")
    func testPreviewStringSinglePhoto() {
        let photoJSON = makePhotoJSON()
        let result = DBLastMessageWithSource.attachmentsPreviewString(attachmentUrls: [photoJSON], count: 1)
        #expect(result == "a photo")
    }

    @Test("Single video attachment shows 'a video'")
    func testPreviewStringSingleVideo() {
        let videoJSON = makeVideoJSON()
        let result = DBLastMessageWithSource.attachmentsPreviewString(attachmentUrls: [videoJSON], count: 1)
        #expect(result == "a video")
    }

    @Test("Multiple photos shows 'N photos'")
    func testPreviewStringMultiplePhotos() {
        let photoJSON = makePhotoJSON()
        let result = DBLastMessageWithSource.attachmentsPreviewString(attachmentUrls: [photoJSON, photoJSON], count: 2)
        #expect(result == "2 photos")
    }

    @Test("Mixed video and photo shows 'N attachments'")
    func testPreviewStringMixedAttachments() {
        let videoJSON = makeVideoJSON()
        let photoJSON = makePhotoJSON()
        let result = DBLastMessageWithSource.attachmentsPreviewString(attachmentUrls: [videoJSON, photoJSON], count: 2)
        #expect(result == "2 attachments")
    }

    @Test("Non-JSON attachment key defaults to 'a photo'")
    func testPreviewStringNonJSONKey() {
        let result = DBLastMessageWithSource.attachmentsPreviewString(attachmentUrls: ["file://local/path"], count: 1)
        #expect(result == "a photo")
    }

    // MARK: - File Attachment Tests

    @Test("MediaType from PDF mimeType")
    func testMediaTypePDF() {
        let attachment = HydratedAttachment(key: "test", mimeType: "application/pdf")
        #expect(attachment.mediaType == .file)
    }

    @Test("MediaType from text mimeType")
    func testMediaTypeText() {
        let attachment = HydratedAttachment(key: "test", mimeType: "text/plain")
        #expect(attachment.mediaType == .file)
    }

    @Test("MediaType from JSON mimeType")
    func testMediaTypeJSON() {
        let attachment = HydratedAttachment(key: "test", mimeType: "application/json")
        #expect(attachment.mediaType == .file)
    }

    @Test("MediaType derived from filename extension when mimeType is nil")
    func testMediaTypeFromFilenameExtension() {
        let attachment = HydratedAttachment(key: "test", filename: "report.pdf")
        #expect(attachment.mediaType == .file)
    }

    @Test("MediaType from filename with image extension stays image when mimeType is nil")
    func testMediaTypeFromImageFilename() {
        let attachment = HydratedAttachment(key: "test", filename: "photo.jpg")
        #expect(attachment.mediaType == .image)
    }

    @Test("MediaType from filename with video extension")
    func testMediaTypeFromVideoFilename() {
        let attachment = HydratedAttachment(key: "test", filename: "clip.mp4")
        #expect(attachment.mediaType == .video)
    }

    @Test("filenameExtension extracts correctly")
    func testFilenameExtension() {
        let attachment = HydratedAttachment(key: "test", filename: "report.pdf")
        #expect(attachment.filenameExtension == "pdf")
    }

    @Test("filenameExtension returns nil for no extension")
    func testFilenameExtensionNil() {
        let attachment = HydratedAttachment(key: "test", filename: "README")
        #expect(attachment.filenameExtension == nil)
    }

    @Test("fileTypeLabel returns localized description for PDF")
    func testFileTypeLabelPDF() {
        let attachment = HydratedAttachment(key: "test", filename: "test.pdf")
        #expect(attachment.fileTypeLabel != nil)
        #expect(attachment.fileTypeLabel?.contains("PDF") == true)
    }

    @Test("fileTypeLabel from mimeType when filename has no extension")
    func testFileTypeLabelFromMimeType() {
        let attachment = HydratedAttachment(key: "test", mimeType: "application/pdf")
        #expect(attachment.fileTypeLabel != nil)
    }

    @Test("Single file attachment shows filename in preview")
    func testPreviewStringFile() {
        let fileJSON = makeFileJSON(filename: "report.pdf", mimeType: "application/pdf")
        let result = DBLastMessageWithSource.attachmentsPreviewString(attachmentUrls: [fileJSON], count: 1)
        #expect(result == "report.pdf")
    }

    @Test("Single file without mime but with non-image filename shows 'a file'")
    func testPreviewStringFileNoMime() {
        let fileJSON = makeFileJSON(filename: "data.csv", mimeType: nil)
        let result = DBLastMessageWithSource.attachmentsPreviewString(attachmentUrls: [fileJSON], count: 1)
        #expect(result == "data.csv")
    }

    @Test("Mixed file and photo shows 'N attachments'")
    func testPreviewStringMixedFileAndPhoto() {
        let fileJSON = makeFileJSON(filename: "doc.pdf", mimeType: "application/pdf")
        let photoJSON = makePhotoJSON()
        let result = DBLastMessageWithSource.attachmentsPreviewString(attachmentUrls: [fileJSON, photoJSON], count: 2)
        #expect(result == "2 attachments")
    }

    private func makeFileJSON(filename: String, mimeType: String?) -> String {
        let stored = StoredRemoteAttachment(
            url: "https://example.com/file.enc",
            contentDigest: "abc",
            secret: Data("s".utf8),
            salt: Data("s".utf8),
            nonce: Data("n".utf8),
            filename: filename,
            mimeType: mimeType
        )
        return (try? stored.toJSON()) ?? ""
    }

    private func makePhotoJSON() -> String {
        let stored = StoredRemoteAttachment(
            url: "https://example.com/photo.enc",
            contentDigest: "abc",
            secret: Data("s".utf8),
            salt: Data("s".utf8),
            nonce: Data("n".utf8),
            filename: "photo.jpg"
        )
        return (try? stored.toJSON()) ?? ""
    }

    private func makeVideoJSON() -> String {
        let stored = StoredRemoteAttachment(
            url: "https://example.com/video.enc",
            contentDigest: "abc",
            secret: Data("s".utf8),
            salt: Data("s".utf8),
            nonce: Data("n".utf8),
            filename: "video.mp4",
            mimeType: "video/mp4"
        )
        return (try? stored.toJSON()) ?? ""
    }
}
