import Foundation
@preconcurrency import XMTPiOS

public let ContentTypeJoinRequest = ContentTypeID(
    authorityID: "convos.org",
    typeID: "join_request",
    versionMajor: 1,
    versionMinor: 0
)

public struct JoinRequestContent: Codable, Sendable, Equatable {
    public let inviteSlug: String
    public let profile: JoinRequestProfile?
    public let metadata: [String: String]?

    public init(
        inviteSlug: String,
        profile: JoinRequestProfile? = nil,
        metadata: [String: String]? = nil
    ) {
        self.inviteSlug = inviteSlug
        self.profile = profile
        self.metadata = metadata
    }
}

public struct JoinRequestProfile: Codable, Sendable, Equatable {
    public let name: String?
    public let imageURL: String?
    public let memberKind: String?

    public init(name: String? = nil, imageURL: String? = nil, memberKind: String? = nil) {
        self.name = name
        self.imageURL = imageURL
        self.memberKind = memberKind
    }
}

public enum JoinRequestCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "JoinRequest content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for JoinRequest"
        }
    }
}

public struct JoinRequestCodec: ContentCodec {
    public typealias T = JoinRequestContent

    public var contentType: ContentTypeID = ContentTypeJoinRequest

    public init() {}

    public func encode(content: JoinRequestContent) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeJoinRequest
        encodedContent.content = try JSONEncoder().encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> JoinRequestContent {
        guard !content.content.isEmpty else {
            throw JoinRequestCodecError.emptyContent
        }
        return try JSONDecoder().decode(JoinRequestContent.self, from: content.content)
    }

    public func fallback(content: JoinRequestContent) throws -> String? {
        content.inviteSlug
    }

    public func shouldPush(content: JoinRequestContent) throws -> Bool {
        true
    }
}
