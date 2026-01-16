#if canImport(UIKit)
import Foundation
import UIKit
@preconcurrency import XMTPiOS

public enum PhotoAttachmentError: Error {
    case compressionFailed
    case encryptionFailed
    case uploadFailed(String)
    case invalidURL
    case localSaveFailed
}

public struct PreparedPhotoAttachment: Sendable {
    public let remoteAttachment: RemoteAttachment
    public let localDisplayURL: URL
}

public protocol PhotoAttachmentServiceProtocol: Sendable {
    func prepareForSend(
        image: UIImage,
        apiClient: any ConvosAPIClientProtocol,
        filename: String
    ) async throws -> PreparedPhotoAttachment

    func generateFilename() -> String
    func localCacheURL(for filename: String) -> URL
}

public final class PhotoAttachmentService: PhotoAttachmentServiceProtocol, Sendable {
    public init() {}

    public func generateFilename() -> String {
        "photo_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).jpg"
    }

    public func localCacheURL(for filename: String) -> URL {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            fatalError("Unable to access cache directory")
        }
        let photosDir = cacheDir.appendingPathComponent("SentPhotos", isDirectory: true)
        return photosDir.appendingPathComponent(filename)
    }

    public func prepareForSend(
        image: UIImage,
        apiClient: any ConvosAPIClientProtocol,
        filename: String
    ) async throws -> PreparedPhotoAttachment {
        guard let compressedData = ImageCompression.compressForPhotoAttachment(image) else {
            throw PhotoAttachmentError.compressionFailed
        }

        let localURL = try saveToLocalCache(data: compressedData, filename: filename)

        let attachment = Attachment(filename: filename, mimeType: "image/jpeg", data: compressedData)

        let encrypted = try RemoteAttachment.encodeEncrypted(
            content: attachment,
            codec: AttachmentCodec()
        )

        let uploadedURL = try await apiClient.uploadAttachment(
            data: encrypted.payload,
            filename: filename,
            contentType: "application/octet-stream",
            acl: "public-read"
        )

        guard let url = URL(string: uploadedURL) else {
            throw PhotoAttachmentError.invalidURL
        }

        let remoteAttachment = try RemoteAttachment(
            url: url.absoluteString,
            encryptedEncodedContent: encrypted
        )

        return PreparedPhotoAttachment(
            remoteAttachment: remoteAttachment,
            localDisplayURL: localURL
        )
    }

    private func saveToLocalCache(data: Data, filename: String) throws -> URL {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw PhotoAttachmentError.compressionFailed
        }
        let photosDir = cacheDir.appendingPathComponent("SentPhotos", isDirectory: true)

        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)

        let fileURL = photosDir.appendingPathComponent(filename)
        try data.write(to: fileURL)

        return fileURL
    }
}
#endif
