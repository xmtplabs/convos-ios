import ConvosConnections
import Foundation
@preconcurrency import XMTPiOS

/// Wire content type for `ConnectionInvocationResult` (device → agent write outcomes).
public let ContentTypeConnectionInvocationResult = ContentTypeID(
    authorityID: "convos.org",
    typeID: "connection_invocation_result",
    versionMajor: 1,
    versionMinor: 0
)

public enum ConnectionInvocationResultCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent: return "ConnectionInvocationResult content is empty"
        case .invalidJSONFormat: return "Invalid JSON format for ConnectionInvocationResult"
        }
    }
}

public struct ConnectionInvocationResultCodec: ContentCodec {
    public typealias T = ConnectionInvocationResult

    public var contentType: ContentTypeID = ContentTypeConnectionInvocationResult

    public init() {}

    public func encode(content: ConnectionInvocationResult) throws -> EncodedContent {
        var encoded = EncodedContent()
        encoded.type = ContentTypeConnectionInvocationResult
        encoded.content = try JSONEncoder().encode(content)
        return encoded
    }

    public func decode(content: EncodedContent) throws -> ConnectionInvocationResult {
        guard !content.content.isEmpty else {
            throw ConnectionInvocationResultCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(ConnectionInvocationResult.self, from: content.content)
        } catch {
            throw ConnectionInvocationResultCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: ConnectionInvocationResult) throws -> String? {
        "Connection result"
    }

    public func shouldPush(content: ConnectionInvocationResult) throws -> Bool {
        false
    }
}
