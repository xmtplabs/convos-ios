import Foundation
@preconcurrency import XMTPiOS

public struct ConnectionEvent: Codable, Sendable, Hashable {
    public static let supportedVersion: Int = 1

    public enum Action: String, Codable, Sendable, Hashable {
        case granted
        case revoked
    }

    public let version: Int
    public let providerId: String
    public let action: Action

    public init(version: Int = ConnectionEvent.supportedVersion, providerId: String, action: Action) {
        self.version = version
        self.providerId = providerId
        self.action = action
    }
}

public let ContentTypeConnectionEvent = ContentTypeID(
    authorityID: "convos.org",
    typeID: "connection_event",
    versionMajor: 1,
    versionMinor: 0
)

public struct ConnectionEventCodec: ContentCodec {
    public typealias T = ConnectionEvent

    public var contentType: ContentTypeID = ContentTypeConnectionEvent

    public init() {}

    public func encode(content: ConnectionEvent) throws -> EncodedContent {
        var encoded = EncodedContent()
        encoded.type = ContentTypeConnectionEvent
        encoded.content = try JSONEncoder().encode(content)
        return encoded
    }

    public func decode(content: EncodedContent) throws -> ConnectionEvent {
        try JSONDecoder().decode(ConnectionEvent.self, from: content.content)
    }

    public func fallback(content: ConnectionEvent) throws -> String? {
        nil
    }

    public func shouldPush(content: ConnectionEvent) throws -> Bool {
        false
    }
}
