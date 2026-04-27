import ConvosMessagingProtocols
import Foundation
// FIXME: see docs/outstanding-messaging-abstraction-work.md#codec-migration
@preconcurrency import XMTPiOS

public enum RemoteAttachmentLoaderError: Error {
    case invalidAttachmentData
    case reconstructionFailed
    case decryptionFailed
    case notAnImage
}

public struct LoadedAttachment: Sendable {
    public let data: Data
    public let mimeType: String
    public let filename: String?

    public init(data: Data, mimeType: String, filename: String?) {
        self.data = data
        self.mimeType = mimeType
        self.filename = filename
    }
}

public protocol RemoteAttachmentLoaderProtocol: Sendable {
    func loadImageData(from storedJSON: String) async throws -> Data
    func loadAttachmentData(from storedJSON: String) async throws -> LoadedAttachment
}

public actor RemoteAttachmentLoader: RemoteAttachmentLoaderProtocol {
    private var inFlightTasks: [String: Task<LoadedAttachment, Error>] = [:]

    public init() {}

    public func loadImageData(from storedJSON: String) async throws -> Data {
        let loaded = try await loadAttachmentData(from: storedJSON)
        return loaded.data
    }

    public func loadAttachmentData(from storedJSON: String) async throws -> LoadedAttachment {
        let requestKey = storedJSON.hash.description

        if let existingTask = inFlightTasks[requestKey] {
            return try await existingTask.value
        }

        let task = Task<LoadedAttachment, Error> {
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

    private func fetchAndDecrypt(storedJSON: String) async throws -> LoadedAttachment {
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

        return LoadedAttachment(
            data: attachment.data,
            mimeType: attachment.mimeType,
            filename: attachment.filename
        )
    }
}
