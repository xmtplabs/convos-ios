import ConvosConnections
import Foundation
@preconcurrency import XMTPiOS

/// Wire content type for `ConnectionPayload` (device → agent sensor events).
public let ContentTypeConnectionPayload = ContentTypeID(
    authorityID: "convos.org",
    typeID: "connection_payload",
    versionMajor: 1,
    versionMinor: 0
)

public enum ConnectionPayloadCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent: return "ConnectionPayload content is empty"
        case .invalidJSONFormat: return "Invalid JSON format for ConnectionPayload"
        }
    }
}

public struct ConnectionPayloadCodec: ContentCodec {
    public typealias T = ConnectionPayload

    public var contentType: ContentTypeID = ContentTypeConnectionPayload

    public init() {}

    public func encode(content: ConnectionPayload) throws -> EncodedContent {
        var encoded = EncodedContent()
        encoded.type = ContentTypeConnectionPayload
        encoded.content = try JSONEncoder().encode(content)
        return encoded
    }

    public func decode(content: EncodedContent) throws -> ConnectionPayload {
        guard !content.content.isEmpty else {
            throw ConnectionPayloadCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(ConnectionPayload.self, from: content.content)
        } catch {
            throw ConnectionPayloadCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: ConnectionPayload) throws -> String? {
        "Connection event"
    }

    public func shouldPush(content: ConnectionPayload) throws -> Bool {
        false
    }
}
