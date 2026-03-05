import Foundation
@preconcurrency import XMTPiOS

public let ContentTypeDeviceRemoved = ContentTypeID(
    authorityID: "convos.org",
    typeID: "device_removed",
    versionMajor: 1,
    versionMinor: 0
)

public enum DeviceRemovedReason: Codable, Sendable, Equatable {
    case userRemoved
    case lostDevice
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .userRemoved: return "user_removed"
        case .lostDevice: return "lost_device"
        case .unknown(let value): return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "user_removed": self = .userRemoved
        case "lost_device": self = .lostDevice
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct DeviceRemovedContent: Codable, Sendable, Equatable {
    public let removedInboxId: String
    public let reason: DeviceRemovedReason
    public let timestamp: Date

    public init(
        removedInboxId: String,
        reason: DeviceRemovedReason,
        timestamp: Date = Date()
    ) {
        self.removedInboxId = removedInboxId
        self.reason = reason
        self.timestamp = timestamp
    }
}

public enum DeviceRemovedCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "DeviceRemoved content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for DeviceRemoved"
        }
    }
}

public struct DeviceRemovedCodec: ContentCodec {
    public typealias T = DeviceRemovedContent

    public var contentType: ContentTypeID = ContentTypeDeviceRemoved

    public init() {}

    public func encode(content: DeviceRemovedContent) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeDeviceRemoved
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encodedContent.content = try encoder.encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> DeviceRemovedContent {
        guard !content.content.isEmpty else {
            throw DeviceRemovedCodecError.emptyContent
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DeviceRemovedContent.self, from: content.content)
    }

    public func fallback(content: DeviceRemovedContent) throws -> String? {
        "Device removed"
    }

    public func shouldPush(content: DeviceRemovedContent) throws -> Bool {
        false
    }
}
