import Foundation
@preconcurrency import XMTPiOS

public struct ConnectionGrantRequest: Codable, Sendable, Hashable {
    public let version: Int
    public let service: String
    public let requestedByInboxId: String
    public let targetInboxId: String
    public let reason: String

    public init(
        version: Int = 1,
        service: String,
        requestedByInboxId: String,
        targetInboxId: String,
        reason: String
    ) {
        self.version = version
        self.service = service
        self.requestedByInboxId = requestedByInboxId
        self.targetInboxId = targetInboxId
        self.reason = reason
    }
}

public let ContentTypeConnectionGrantRequest = ContentTypeID(
    authorityID: "convos.org",
    typeID: "connection_grant_request",
    versionMajor: 1,
    versionMinor: 0
)

public enum ConnectionGrantRequestCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            "ConnectionGrantRequest content is empty"
        case .invalidJSONFormat:
            "Invalid JSON format for ConnectionGrantRequest"
        }
    }
}

public struct ConnectionGrantRequestCodec: ContentCodec {
    public typealias T = ConnectionGrantRequest

    public var contentType: ContentTypeID = ContentTypeConnectionGrantRequest

    public init() {}

    public func encode(content: ConnectionGrantRequest) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeConnectionGrantRequest
        encodedContent.content = try JSONEncoder().encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> ConnectionGrantRequest {
        guard !content.content.isEmpty else {
            throw ConnectionGrantRequestCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(ConnectionGrantRequest.self, from: content.content)
        } catch {
            throw ConnectionGrantRequestCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: ConnectionGrantRequest) throws -> String? {
        "The assistant asked to connect \(content.service)"
    }

    public func shouldPush(content: ConnectionGrantRequest) throws -> Bool {
        false
    }
}
