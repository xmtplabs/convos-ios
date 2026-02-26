import Foundation
@preconcurrency import XMTPiOS

public let ContentTypeInviteJoinError = ContentTypeID(
    authorityID: "convos.org",
    typeID: "invite_join_error",
    versionMajor: 1,
    versionMinor: 0
)

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

    public init() {}

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
