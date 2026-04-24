import Foundation
@preconcurrency import XMTPiOS

public struct ConnectionGrantRequest: Codable, Sendable, Hashable {
    /// Highest protocol version this client understands. Payloads with a larger
    /// version must be rejected so that we don't render untrusted future fields.
    public static let supportedVersion: Int = 1

    /// Cap on the `reason` field. Anything longer is truncated on decode so a
    /// hostile sender can't bloat the local DB or the card UI.
    public static let maxReasonLength: Int = 500

    public let version: Int
    public let service: String
    public let requestedByInboxId: String
    public let targetInboxId: String
    public let reason: String

    public init(
        version: Int = ConnectionGrantRequest.supportedVersion,
        service: String,
        requestedByInboxId: String,
        targetInboxId: String,
        reason: String
    ) {
        self.version = version
        self.service = service
        self.requestedByInboxId = requestedByInboxId
        self.targetInboxId = targetInboxId
        self.reason = Self.truncatedReason(reason)
    }

    private enum CodingKeys: String, CodingKey {
        case version, service, requestedByInboxId, targetInboxId, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.service = try container.decode(String.self, forKey: .service)
        self.requestedByInboxId = try container.decode(String.self, forKey: .requestedByInboxId)
        self.targetInboxId = try container.decode(String.self, forKey: .targetInboxId)
        let rawReason = try container.decode(String.self, forKey: .reason)
        self.reason = Self.truncatedReason(rawReason)
    }

    private static func truncatedReason(_ reason: String) -> String {
        guard reason.count > maxReasonLength else { return reason }
        return String(reason.prefix(maxReasonLength))
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
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            "ConnectionGrantRequest content is empty"
        case .invalidJSONFormat:
            "Invalid JSON format for ConnectionGrantRequest"
        case .unsupportedVersion(let version):
            "Unsupported ConnectionGrantRequest version \(version)"
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
        let decoded: ConnectionGrantRequest
        do {
            decoded = try JSONDecoder().decode(ConnectionGrantRequest.self, from: content.content)
        } catch {
            throw ConnectionGrantRequestCodecError.invalidJSONFormat
        }
        guard decoded.version <= ConnectionGrantRequest.supportedVersion else {
            throw ConnectionGrantRequestCodecError.unsupportedVersion(decoded.version)
        }
        return decoded
    }

    public func fallback(content: ConnectionGrantRequest) throws -> String? {
        "The assistant asked to connect \(content.service)"
    }

    public func shouldPush(content: ConnectionGrantRequest) throws -> Bool {
        false
    }
}
