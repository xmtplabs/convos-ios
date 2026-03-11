import Foundation
@preconcurrency import XMTPiOS

public struct AssistantJoinRequest: Codable, Sendable {
    public let status: AssistantJoinStatus
    public let requestedByInboxId: String
    public let requestId: String

    public init(status: AssistantJoinStatus, requestedByInboxId: String, requestId: String) {
        self.status = status
        self.requestedByInboxId = requestedByInboxId
        self.requestId = requestId
    }
}

public let ContentTypeAssistantJoinRequest = ContentTypeID(
    authorityID: "convos.org",
    typeID: "assistant_join_request",
    versionMajor: 1,
    versionMinor: 0
)

public enum AssistantJoinRequestCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "AssistantJoinRequest content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for AssistantJoinRequest"
        }
    }
}

public struct AssistantJoinRequestCodec: ContentCodec {
    public typealias T = AssistantJoinRequest

    public var contentType: ContentTypeID = ContentTypeAssistantJoinRequest

    public init() {}

    public func encode(content: AssistantJoinRequest) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeAssistantJoinRequest
        encodedContent.content = try JSONEncoder().encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> AssistantJoinRequest {
        guard !content.content.isEmpty else {
            throw AssistantJoinRequestCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(AssistantJoinRequest.self, from: content.content)
        } catch {
            throw AssistantJoinRequestCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: AssistantJoinRequest) throws -> String? {
        "Assistant join requested"
    }

    public func shouldPush(content: AssistantJoinRequest) throws -> Bool {
        false
    }
}
