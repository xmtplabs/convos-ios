import Foundation
@preconcurrency import XMTPiOS

/// A user's request to interrupt or restart an agent's thinking session.
/// `stop` asks the agent to halt the session anchored to `targetMessageId`;
/// `resume` asks it to pick the session back up. The agent acknowledges by
/// emitting its own `convos.org/thinking:1.0` events (`stop` / `start`), so
/// these actions are requests, not state transitions.
public enum ThinkingControlAction: String, Codable, Sendable {
    case stop
    case resume
}

/// Payload of a `convos.org/thinking-control:1.0` message. `agentInboxId`
/// plus `targetMessageId` identify the session the same way the thinking
/// codec does (a session is keyed by the agent and the message it is
/// thinking about), so two agents thinking about the same message stay
/// independently controllable.
public struct ThinkingControlContent: Codable, Sendable, Equatable {
    public let action: ThinkingControlAction
    public let targetMessageId: String
    public let agentInboxId: String

    public init(action: ThinkingControlAction, targetMessageId: String, agentInboxId: String) {
        self.action = action
        self.targetMessageId = targetMessageId
        self.agentInboxId = agentInboxId
    }
}

public let ContentTypeThinkingControl = ContentTypeID(
    authorityID: "convos.org",
    typeID: "thinking-control",
    versionMajor: 1,
    versionMinor: 0
)

public enum ThinkingControlCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat
    case missingTargetMessageId
    case missingAgentInboxId
    case unknownAction(String)

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "ThinkingControl content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for ThinkingControl"
        case .missingTargetMessageId:
            return "ThinkingControl payload is missing targetMessageId"
        case .missingAgentInboxId:
            return "ThinkingControl payload is missing agentInboxId"
        case let .unknownAction(value):
            return "ThinkingControl payload has unknown action '\(value)'"
        }
    }
}

/// Silent custom content type carrying a stop/resume request for an agent's
/// thinking session. Mirrors `ThinkingCodec`: never written to the chat
/// history table, never pushes a notification, routed through a side-channel
/// handler (see `StreamProcessor.processThinkingControl`) into
/// `ThinkingControlWriter` so every client agrees on the last action sent.
public struct ThinkingControlCodec: ContentCodec {
    public typealias T = ThinkingControlContent

    public var contentType: ContentTypeID = ContentTypeThinkingControl

    public init() {}

    public func encode(content: ThinkingControlContent) throws -> EncodedContent {
        var encoded = EncodedContent()
        encoded.type = ContentTypeThinkingControl
        encoded.content = try JSONEncoder().encode(content)
        return encoded
    }

    public func decode(content: EncodedContent) throws -> ThinkingControlContent {
        guard !content.content.isEmpty else {
            throw ThinkingControlCodecError.emptyContent
        }
        // Decode through a permissive shape first so each required field
        // produces a specific error rather than the JSONDecoder's generic
        // "keyNotFound" / "dataCorrupted". A malformed control message is
        // dropped loudly instead of silently mis-routing.
        struct RawThinkingControl: Decodable {
            let action: String?
            let targetMessageId: String?
            let agentInboxId: String?
        }
        let raw: RawThinkingControl
        do {
            raw = try JSONDecoder().decode(RawThinkingControl.self, from: content.content)
        } catch {
            throw ThinkingControlCodecError.invalidJSONFormat
        }
        guard let rawAction = raw.action, !rawAction.isEmpty else {
            throw ThinkingControlCodecError.unknownAction("")
        }
        guard let action = ThinkingControlAction(rawValue: rawAction) else {
            throw ThinkingControlCodecError.unknownAction(rawAction)
        }
        guard let targetMessageId = raw.targetMessageId, !targetMessageId.isEmpty else {
            throw ThinkingControlCodecError.missingTargetMessageId
        }
        guard let agentInboxId = raw.agentInboxId, !agentInboxId.isEmpty else {
            throw ThinkingControlCodecError.missingAgentInboxId
        }
        return ThinkingControlContent(
            action: action,
            targetMessageId: targetMessageId,
            agentInboxId: agentInboxId
        )
    }

    public func fallback(content: ThinkingControlContent) throws -> String? {
        nil
    }

    public func shouldPush(content: ThinkingControlContent) throws -> Bool {
        false
    }
}
