import Foundation
@preconcurrency import XMTPiOS

public let ContentTypeInviteJoinHandled = ContentTypeID(
    authorityID: "convos.org",
    typeID: "invite_join_handled",
    versionMajor: 1,
    versionMinor: 0
)

public enum InviteJoinHandledCodecError: Error, LocalizedError {
    case emptyContent

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "InviteJoinHandled content is empty"
        }
    }
}

public struct InviteJoinHandledCodec: ContentCodec {
    public typealias T = InviteJoinHandled

    public var contentType: ContentTypeID = ContentTypeInviteJoinHandled

    public init() {}

    public func encode(content: InviteJoinHandled) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeInviteJoinHandled

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encodedContent.content = try encoder.encode(content)

        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> InviteJoinHandled {
        guard !content.content.isEmpty else {
            throw InviteJoinHandledCodecError.emptyContent
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(InviteJoinHandled.self, from: content.content)
    }

    public func fallback(content: InviteJoinHandled) throws -> String? {
        // Creator-side bookkeeping; joiners and older clients have nothing
        // to show for it.
        nil
    }

    public func shouldPush(content: InviteJoinHandled) throws -> Bool {
        false
    }
}
