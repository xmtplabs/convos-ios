import Foundation
@preconcurrency import XMTPiOS

public let ContentTypeDeviceKeyShare = ContentTypeID(
    authorityID: "convos.org",
    typeID: "device_key_share",
    versionMajor: 1,
    versionMinor: 0
)

public struct DeviceKeyShareContent: Codable, Sendable, Equatable {
    public let conversationId: String
    public let inboxId: String
    public let clientId: String
    public let privateKeyData: Data
    public let databaseKey: Data
    public let senderInstallationId: String
    public let senderDeviceName: String?
    public let timestamp: Date

    public init(
        conversationId: String,
        inboxId: String,
        clientId: String,
        privateKeyData: Data,
        databaseKey: Data,
        senderInstallationId: String,
        senderDeviceName: String? = nil,
        timestamp: Date = Date()
    ) {
        self.conversationId = conversationId
        self.inboxId = inboxId
        self.clientId = clientId
        self.privateKeyData = privateKeyData
        self.databaseKey = databaseKey
        self.senderInstallationId = senderInstallationId
        self.senderDeviceName = senderDeviceName
        self.timestamp = timestamp
    }
}

public enum DeviceKeyShareCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "DeviceKeyShare content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for DeviceKeyShare"
        }
    }
}

public struct DeviceKeyShareCodec: ContentCodec {
    public typealias T = DeviceKeyShareContent

    public var contentType: ContentTypeID = ContentTypeDeviceKeyShare

    public init() {}

    public func encode(content: DeviceKeyShareContent) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeDeviceKeyShare
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encodedContent.content = try encoder.encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> DeviceKeyShareContent {
        guard !content.content.isEmpty else {
            throw DeviceKeyShareCodecError.emptyContent
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DeviceKeyShareContent.self, from: content.content)
    }

    public func fallback(content: DeviceKeyShareContent) throws -> String? {
        "Shared key for conversation \(content.conversationId)"
    }

    public func shouldPush(content: DeviceKeyShareContent) throws -> Bool {
        false
    }
}
