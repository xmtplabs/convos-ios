import Foundation
@preconcurrency import XMTPiOS

public struct AgentJoinRequest: Codable, Sendable {
    public let status: AgentJoinStatus
    public let requestedByInboxId: String
    public let requestId: String

    public init(status: AgentJoinStatus, requestedByInboxId: String, requestId: String) {
        self.status = status
        self.requestedByInboxId = requestedByInboxId
        self.requestId = requestId
    }
}

public let ContentTypeAgentJoinRequest = ContentTypeID(
    authorityID: "convos.org",
    typeID: "assistant_join_request",
    versionMajor: 1,
    versionMinor: 0
)

public enum AgentJoinRequestCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "AgentJoinRequest content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for AgentJoinRequest"
        }
    }
}

public struct AgentJoinRequestCodec: ContentCodec {
    public typealias T = AgentJoinRequest

    public var contentType: ContentTypeID = ContentTypeAgentJoinRequest

    public init() {}

    public func encode(content: AgentJoinRequest) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeAgentJoinRequest
        encodedContent.content = try JSONEncoder().encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> AgentJoinRequest {
        guard !content.content.isEmpty else {
            throw AgentJoinRequestCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(AgentJoinRequest.self, from: content.content)
        } catch {
            throw AgentJoinRequestCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: AgentJoinRequest) throws -> String? {
        "Agent join requested"
    }

    public func shouldPush(content: AgentJoinRequest) throws -> Bool {
        false
    }
}
