import Foundation
@preconcurrency import XMTPiOS

/// Payload of a `convos.org/brainstorm-anchor:1.0` message. Sent when a user
/// starts a brainstorm thread with an agent that has not yet emitted any
/// `convos.org/thinking:1.0` messages, so the thread's reply chain has a
/// message id to reference. `agentInboxId` names the agent the thread
/// belongs to; brainstorm replies referencing this anchor are routed to
/// that agent's brainstorm tab.
public struct BrainstormAnchorContent: Codable, Sendable, Equatable {
    public let agentInboxId: String

    public init(agentInboxId: String) {
        self.agentInboxId = agentInboxId
    }
}

public let ContentTypeBrainstormAnchor = ContentTypeID(
    authorityID: "convos.org",
    typeID: "brainstorm-anchor",
    versionMajor: 1,
    versionMinor: 0
)

public enum BrainstormAnchorCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat
    case missingAgentInboxId

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "BrainstormAnchor content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for BrainstormAnchor"
        case .missingAgentInboxId:
            return "BrainstormAnchor payload is missing agentInboxId"
        }
    }
}

/// Silent custom content type that opens a brainstorm reply chain. Mirrors
/// `ThinkingCodec`: never written to the chat history table, never pushes a
/// notification, routed through a side-channel handler (see
/// `StreamProcessor.processBrainstormAnchor`) into the `brainstormAnchor`
/// table so brainstorm replies can be recognized by their reference id.
public struct BrainstormAnchorCodec: ContentCodec {
    public typealias T = BrainstormAnchorContent

    public var contentType: ContentTypeID = ContentTypeBrainstormAnchor

    public init() {}

    public func encode(content: BrainstormAnchorContent) throws -> EncodedContent {
        var encoded = EncodedContent()
        encoded.type = ContentTypeBrainstormAnchor
        encoded.content = try JSONEncoder().encode(content)
        return encoded
    }

    public func decode(content: EncodedContent) throws -> BrainstormAnchorContent {
        guard !content.content.isEmpty else {
            throw BrainstormAnchorCodecError.emptyContent
        }
        struct RawAnchor: Decodable {
            let agentInboxId: String?
        }
        let raw: RawAnchor
        do {
            raw = try JSONDecoder().decode(RawAnchor.self, from: content.content)
        } catch {
            throw BrainstormAnchorCodecError.invalidJSONFormat
        }
        guard let agentInboxId = raw.agentInboxId, !agentInboxId.isEmpty else {
            throw BrainstormAnchorCodecError.missingAgentInboxId
        }
        return BrainstormAnchorContent(agentInboxId: agentInboxId)
    }

    public func fallback(content: BrainstormAnchorContent) throws -> String? {
        nil
    }

    public func shouldPush(content: BrainstormAnchorContent) throws -> Bool {
        false
    }
}
