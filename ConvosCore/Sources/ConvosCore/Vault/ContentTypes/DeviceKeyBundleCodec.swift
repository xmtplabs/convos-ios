import Foundation
@preconcurrency import XMTPiOS

public let ContentTypeDeviceKeyBundle = ContentTypeID(
    authorityID: "convos.org",
    typeID: "device_key_bundle",
    versionMajor: 1,
    versionMinor: 0
)

public struct DeviceKeyEntry: Codable, Sendable, Equatable {
    public let conversationId: String
    public let inboxId: String
    public let clientId: String
    public let privateKeyData: Data
    public let databaseKey: Data

    public init(
        conversationId: String,
        inboxId: String,
        clientId: String,
        privateKeyData: Data,
        databaseKey: Data
    ) {
        self.conversationId = conversationId
        self.inboxId = inboxId
        self.clientId = clientId
        self.privateKeyData = privateKeyData
        self.databaseKey = databaseKey
    }
}

public struct DeviceKeyBundleContent: Codable, Sendable, Equatable {
    public let keys: [DeviceKeyEntry]
    public let senderInstallationId: String
    public let senderDeviceName: String?
    public let peerDeviceNames: [String: String]?
    public let timestamp: Date

    public init(
        keys: [DeviceKeyEntry],
        senderInstallationId: String,
        senderDeviceName: String? = nil,
        peerDeviceNames: [String: String]? = nil,
        timestamp: Date = Date()
    ) {
        self.keys = keys
        self.senderInstallationId = senderInstallationId
        self.senderDeviceName = senderDeviceName
        self.peerDeviceNames = peerDeviceNames
        self.timestamp = timestamp
    }
}

public enum DeviceKeyBundleCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "DeviceKeyBundle content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for DeviceKeyBundle"
        }
    }
}

public struct DeviceKeyBundleCodec: ContentCodec {
    public typealias T = DeviceKeyBundleContent

    public var contentType: ContentTypeID = ContentTypeDeviceKeyBundle

    public init() {}

    public func encode(content: DeviceKeyBundleContent) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeDeviceKeyBundle
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encodedContent.content = try encoder.encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> DeviceKeyBundleContent {
        guard !content.content.isEmpty else {
            throw DeviceKeyBundleCodecError.emptyContent
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DeviceKeyBundleContent.self, from: content.content)
    }

    public func fallback(content: DeviceKeyBundleContent) throws -> String? {
        "Shared \(content.keys.count) conversation keys"
    }

    public func shouldPush(content: DeviceKeyBundleContent) throws -> Bool {
        false
    }
}
