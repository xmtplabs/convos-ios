import Foundation

public struct StoredRemoteAttachment: Codable, Hashable, Sendable {
    public let url: String
    public let contentDigest: String
    public let secret: Data
    public let salt: Data
    public let nonce: Data
    public let filename: String?
    public let mimeType: String?
    public let mediaWidth: Int?
    public let mediaHeight: Int?
    public let mediaDuration: Double?
    public let thumbnailDataBase64: String?

    public init(
        url: String,
        contentDigest: String,
        secret: Data,
        salt: Data,
        nonce: Data,
        filename: String?,
        mimeType: String? = nil,
        mediaWidth: Int? = nil,
        mediaHeight: Int? = nil,
        mediaDuration: Double? = nil,
        thumbnailDataBase64: String? = nil
    ) {
        self.url = url
        self.contentDigest = contentDigest
        self.secret = secret
        self.salt = salt
        self.nonce = nonce
        self.filename = filename
        self.mimeType = mimeType
        self.mediaWidth = mediaWidth
        self.mediaHeight = mediaHeight
        self.mediaDuration = mediaDuration
        self.thumbnailDataBase64 = thumbnailDataBase64
    }

    public func toJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw StoredRemoteAttachmentError.encodingFailed
        }
        return json
    }

    public static func fromJSON(_ json: String) throws -> StoredRemoteAttachment {
        guard let data = json.data(using: .utf8) else {
            throw StoredRemoteAttachmentError.decodingFailed
        }
        let decoder = JSONDecoder()
        return try decoder.decode(StoredRemoteAttachment.self, from: data)
    }
}

public enum StoredRemoteAttachmentError: Error {
    case encodingFailed
    case decodingFailed
}
