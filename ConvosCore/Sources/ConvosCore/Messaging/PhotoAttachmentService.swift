import Foundation
@preconcurrency import XMTPiOS

public enum PhotoAttachmentError: Error {
    case compressionFailed
    case encryptionFailed
    case uploadFailed(String)
    case invalidURL
    case localSaveFailed
    case persistentStorageUnavailable
}

public struct PreparedPhotoAttachment: Sendable {
    public let remoteAttachment: RemoteAttachment
    public let localDisplayURL: URL
}

public struct LocallySavedPhoto: Sendable {
    public let compressedData: Data
    public let localURL: URL
    public let filename: String
}

public struct PreparedBackgroundUpload: Sendable {
    public let taskId: String
    public let encryptedFileURL: URL
    public let presignedUploadURL: URL
    public let assetURL: String
    public let encryptionSecret: Data
    public let encryptionSalt: Data
    public let encryptionNonce: Data
    public let contentDigest: String
    public let filename: String

    public init(
        taskId: String,
        encryptedFileURL: URL,
        presignedUploadURL: URL,
        assetURL: String,
        encryptionSecret: Data,
        encryptionSalt: Data,
        encryptionNonce: Data,
        contentDigest: String,
        filename: String
    ) {
        self.taskId = taskId
        self.encryptedFileURL = encryptedFileURL
        self.presignedUploadURL = presignedUploadURL
        self.assetURL = assetURL
        self.encryptionSecret = encryptionSecret
        self.encryptionSalt = encryptionSalt
        self.encryptionNonce = encryptionNonce
        self.contentDigest = contentDigest
        self.filename = filename
    }
}

public protocol PhotoAttachmentServiceProtocol: Sendable {
    func prepareForSend(
        image: ImageType,
        apiClient: any ConvosAPIClientProtocol,
        filename: String
    ) async throws -> PreparedPhotoAttachment

    func saveLocally(image: ImageType, filename: String) throws -> LocallySavedPhoto

    func uploadAndPrepare(
        savedPhoto: LocallySavedPhoto,
        apiClient: any ConvosAPIClientProtocol
    ) async throws -> PreparedPhotoAttachment

    func prepareForBackgroundUpload(
        image: ImageType,
        apiClient: any ConvosAPIClientProtocol,
        filename: String
    ) async throws -> PreparedBackgroundUpload

    func generateFilename() -> String
    func localCacheURL(for filename: String) throws -> URL
}

public final class PhotoAttachmentService: PhotoAttachmentServiceProtocol, Sendable {
    public init() {}

    public func generateFilename() -> String {
        "photo_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).jpg"
    }

    public func localCacheURL(for filename: String) throws -> URL {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw PhotoAttachmentError.persistentStorageUnavailable
        }
        let photosDir = cacheDir.appendingPathComponent("SentPhotos", isDirectory: true)
        return photosDir.appendingPathComponent(filename)
    }

    public func saveLocally(image: ImageType, filename: String) throws -> LocallySavedPhoto {
        guard let compressedData = ImageCompression.compressForPhotoAttachment(image) else {
            throw PhotoAttachmentError.compressionFailed
        }
        let localURL = try saveToLocalCache(data: compressedData, filename: filename)
        return LocallySavedPhoto(compressedData: compressedData, localURL: localURL, filename: filename)
    }

    public func uploadAndPrepare(
        savedPhoto: LocallySavedPhoto,
        apiClient: any ConvosAPIClientProtocol
    ) async throws -> PreparedPhotoAttachment {
        let attachment = Attachment(
            filename: savedPhoto.filename,
            mimeType: "image/jpeg",
            data: savedPhoto.compressedData
        )

        let encrypted = try RemoteAttachment.encodeEncrypted(
            content: attachment,
            codec: AttachmentCodec()
        )

        let uploadedURL = try await apiClient.uploadAttachment(
            data: encrypted.payload,
            filename: savedPhoto.filename,
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
            localDisplayURL: savedPhoto.localURL
        )
    }

    public func prepareForSend(
        image: ImageType,
        apiClient: any ConvosAPIClientProtocol,
        filename: String
    ) async throws -> PreparedPhotoAttachment {
        let savedPhoto = try saveLocally(image: image, filename: filename)
        return try await uploadAndPrepare(savedPhoto: savedPhoto, apiClient: apiClient)
    }

    public func prepareForBackgroundUpload(
        image: ImageType,
        apiClient: any ConvosAPIClientProtocol,
        filename: String
    ) async throws -> PreparedBackgroundUpload {
        guard let compressedData = ImageCompression.compressForPhotoAttachment(image) else {
            throw PhotoAttachmentError.compressionFailed
        }

        let attachment = Attachment(
            filename: filename,
            mimeType: "image/jpeg",
            data: compressedData
        )

        let encrypted = try RemoteAttachment.encodeEncrypted(
            content: attachment,
            codec: AttachmentCodec()
        )

        let presignedURLs = try await apiClient.getPresignedUploadURL(
            filename: filename,
            contentType: "application/octet-stream"
        )

        guard let uploadURL = URL(string: presignedURLs.uploadURL) else {
            throw PhotoAttachmentError.invalidURL
        }

        let taskId = UUID().uuidString
        let encryptedFileURL = try saveToPendingUploads(data: encrypted.payload, taskId: taskId)

        return PreparedBackgroundUpload(
            taskId: taskId,
            encryptedFileURL: encryptedFileURL,
            presignedUploadURL: uploadURL,
            assetURL: presignedURLs.assetURL,
            encryptionSecret: encrypted.secret,
            encryptionSalt: encrypted.salt,
            encryptionNonce: encrypted.nonce,
            contentDigest: encrypted.digest,
            filename: filename
        )
    }

    private func pendingUploadsDirectory() throws -> URL {
        guard let appSupportDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PhotoAttachmentError.persistentStorageUnavailable
        }
        return appSupportDir.appendingPathComponent("PendingUploads", isDirectory: true)
    }

    private func saveToPendingUploads(data: Data, taskId: String) throws -> URL {
        let pendingDir = try pendingUploadsDirectory()
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)

        let fileURL = pendingDir.appendingPathComponent("\(taskId).enc")
        try data.write(to: fileURL)

        return fileURL
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
