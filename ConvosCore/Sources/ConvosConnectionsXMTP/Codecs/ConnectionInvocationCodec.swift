import ConvosConnections
import Foundation
@preconcurrency import XMTPiOS

/// Wire content type for `ConnectionInvocation` (agent → device write requests).
public let ContentTypeConnectionInvocation = ContentTypeID(
    authorityID: "convos.org",
    typeID: "connection_invocation",
    versionMajor: 1,
    versionMinor: 0
)

public enum ConnectionInvocationCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent: return "ConnectionInvocation content is empty"
        case .invalidJSONFormat: return "Invalid JSON format for ConnectionInvocation"
        }
    }
}

public struct ConnectionInvocationCodec: ContentCodec {
    public typealias T = ConnectionInvocation

    public var contentType: ContentTypeID = ContentTypeConnectionInvocation

    public init() {}

    public func encode(content: ConnectionInvocation) throws -> EncodedContent {
        var encoded = EncodedContent()
        encoded.type = ContentTypeConnectionInvocation
        encoded.content = try JSONEncoder().encode(content)
        return encoded
    }

    public func decode(content: EncodedContent) throws -> ConnectionInvocation {
        guard !content.content.isEmpty else {
            throw ConnectionInvocationCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(ConnectionInvocation.self, from: content.content)
        } catch {
            throw ConnectionInvocationCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: ConnectionInvocation) throws -> String? {
        "Connection invocation"
    }

    public func shouldPush(content: ConnectionInvocation) throws -> Bool {
        false
    }
}
