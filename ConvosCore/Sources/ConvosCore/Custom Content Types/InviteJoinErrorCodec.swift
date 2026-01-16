import Foundation
import XMTPiOS

public enum InviteJoinErrorType: Equatable, Sendable {
    case conversationExpired
    case genericFailure
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .conversationExpired:
            return "conversation_expired"
        case .genericFailure:
            return "generic_failure"
        case .unknown(let value):
            return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "conversation_expired":
            self = .conversationExpired
        case "generic_failure":
            self = .genericFailure
        default:
            self = .unknown(rawValue)
        }
    }
}

extension InviteJoinErrorType: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self.init(rawValue: rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct InviteJoinError: Codable, Equatable, Sendable {
    public let errorType: InviteJoinErrorType
    public let inviteTag: String
    public let timestamp: Date

    public init(errorType: InviteJoinErrorType, inviteTag: String, timestamp: Date) {
        self.errorType = errorType
        self.inviteTag = inviteTag
        self.timestamp = timestamp
    }

    public var userFacingMessage: String {
        switch errorType {
        case .conversationExpired:
            return "This conversation is no longer available"
        case .genericFailure, .unknown:
            return "Failed to join conversation"
        }
    }
}

public let ContentTypeInviteJoinError = ContentTypeID(authorityID: "convos.org", typeID: "invite_join_error", versionMajor: 1, versionMinor: 0)

public enum InviteJoinErrorCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "InviteJoinError content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for InviteJoinError"
        }
    }
}

public struct InviteJoinErrorCodec: ContentCodec {
    public typealias T = InviteJoinError

    public var contentType: ContentTypeID = ContentTypeInviteJoinError

    public func encode(content: InviteJoinError) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeInviteJoinError

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encodedContent.content = try encoder.encode(content)

        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> InviteJoinError {
        guard !content.content.isEmpty else {
            throw InviteJoinErrorCodecError.emptyContent
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(InviteJoinError.self, from: content.content)
    }

    public func fallback(content: InviteJoinError) throws -> String? {
        content.userFacingMessage
    }

    public func shouldPush(content: InviteJoinError) throws -> Bool {
        true
    }
}
