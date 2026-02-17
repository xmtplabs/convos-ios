import Foundation
import XMTPiOS

public enum RemoteAttachmentLoaderError: Error {
    case invalidAttachmentData
    case reconstructionFailed
    case decryptionFailed
    case notAnImage
}

public protocol RemoteAttachmentLoaderProtocol: Sendable {
    func loadImageData(from storedJSON: String) async throws -> Data
}

public actor RemoteAttachmentLoader: RemoteAttachmentLoaderProtocol {
    private var inFlightTasks: [String: Task<Data, Error>] = [:]

    public init() {}

    public func loadImageData(from storedJSON: String) async throws -> Data {
        // Use hash as key for deduplication of in-flight requests
        let requestKey = storedJSON.hash.description

        // Check for existing in-flight request to avoid duplicate fetches
        if let existingTask = inFlightTasks[requestKey] {
            return try await existingTask.value
        }

        let task = Task<Data, Error> {
            try await fetchAndDecrypt(storedJSON: storedJSON)
        }

        inFlightTasks[requestKey] = task

        do {
            let result = try await task.value
            inFlightTasks[requestKey] = nil
            return result
        } catch {
            inFlightTasks[requestKey] = nil
            throw error
        }
    }

    private func fetchAndDecrypt(storedJSON: String) async throws -> Data {
        let stored = try StoredRemoteAttachment.fromJSON(storedJSON)

        let remoteAttachment = try RemoteAttachment(
            url: stored.url,
            contentDigest: stored.contentDigest,
            secret: stored.secret,
            salt: stored.salt,
            nonce: stored.nonce,
            scheme: .https,
            contentLength: nil,
            filename: stored.filename
        )

        let encodedContent = try await remoteAttachment.content()

        let attachment = try AttachmentCodec().decode(content: encodedContent)

        guard attachment.mimeType.hasPrefix("image/") else {
            throw RemoteAttachmentLoaderError.notAnImage
        }

        return attachment.data
    }
}
