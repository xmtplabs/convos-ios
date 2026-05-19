import Foundation
@preconcurrency import XMTPiOS

/// State of an agent's "thinking…" session anchored to a specific message.
/// `start` opens the affordance; `stop` closes it. The CLI agent guarantees
/// a `stop` will follow every `start` it emits.
public enum ThinkingState: String, Codable, Sendable {
    case start
    case stop
}

/// Payload of a `convos.org/thinking:1.0` message. `state`, `targetMessageId`,
/// and `content` are required on every event so receivers can disambiguate
/// concurrent thinking sessions and render a final label after `stop`.
/// `resultMessageId` is optional and only meaningful on `stop`: when present
/// it points at the agent's own reply message that closed the thought, so
/// UIs can link "thought about X" → "replied with Y". Absent means the
/// thinking ended without a reply (cancelled, errored, no-op).
public struct ThinkingContent: Codable, Sendable, Equatable {
    public let state: ThinkingState
    public let targetMessageId: String
    public let content: String
    public let resultMessageId: String?

    public init(state: ThinkingState, targetMessageId: String, content: String, resultMessageId: String? = nil) {
        self.state = state
        self.targetMessageId = targetMessageId
        self.content = content
        self.resultMessageId = resultMessageId
    }
}

public let ContentTypeThinking = ContentTypeID(
    authorityID: "convos.org",
    typeID: "thinking",
    versionMajor: 1,
    versionMinor: 0
)

public enum ThinkingCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat
    case missingTargetMessageId
    case missingContent
    case unknownState(String)
    case emptyResultMessageId

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "Thinking content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for Thinking"
        case .missingTargetMessageId:
            return "Thinking payload is missing targetMessageId"
        case .missingContent:
            return "Thinking payload is missing content"
        case let .unknownState(value):
            return "Thinking payload has unknown state '\(value)'"
        case .emptyResultMessageId:
            return "Thinking payload has resultMessageId field but it is empty"
        }
    }
}

/// Silent custom content type for an agent's "thinking…" status anchored to
/// a specific message. Mirrors the read-receipt pattern: never written to
/// the chat history table, never pushes a notification, routed through a
/// side-channel handler (see `StreamProcessor.processThinking`) into
/// `ThinkingStateManager` on the main app.
public struct ThinkingCodec: ContentCodec {
    public typealias T = ThinkingContent

    public var contentType: ContentTypeID = ContentTypeThinking

    public init() {}

    public func encode(content: ThinkingContent) throws -> EncodedContent {
        var encoded = EncodedContent()
        encoded.type = ContentTypeThinking
        encoded.content = try JSONEncoder().encode(content)
        return encoded
    }

    public func decode(content: EncodedContent) throws -> ThinkingContent {
        guard !content.content.isEmpty else {
            throw ThinkingCodecError.emptyContent
        }
        // Decode through a permissive shape first so we can produce specific
        // errors for each required field rather than the JSONDecoder's
        // generic "keyNotFound" / "dataCorrupted". The CLI side promises
        // every field is always present on every message; if any is missing
        // we'd rather drop the message loudly than silently mis-render.
        struct RawThinking: Decodable {
            let state: String?
            let targetMessageId: String?
            let content: String?
            let resultMessageId: String?
        }
        let raw: RawThinking
        do {
            raw = try JSONDecoder().decode(RawThinking.self, from: content.content)
        } catch {
            throw ThinkingCodecError.invalidJSONFormat
        }
        guard let rawState = raw.state, !rawState.isEmpty else {
            throw ThinkingCodecError.unknownState("")
        }
        guard let state = ThinkingState(rawValue: rawState) else {
            throw ThinkingCodecError.unknownState(rawState)
        }
        guard let targetMessageId = raw.targetMessageId, !targetMessageId.isEmpty else {
            throw ThinkingCodecError.missingTargetMessageId
        }
        guard let text = raw.content, !text.isEmpty else {
            throw ThinkingCodecError.missingContent
        }
        // resultMessageId is optional. Present-but-empty is invalid (the
        // sender chose to include the field; an empty value is meaningless).
        // Absent → fine, the agent didn't link a reply.
        let resultMessageId: String?
        if let raw = raw.resultMessageId {
            guard !raw.isEmpty else {
                throw ThinkingCodecError.emptyResultMessageId
            }
            resultMessageId = raw
        } else {
            resultMessageId = nil
        }
        return ThinkingContent(
            state: state,
            targetMessageId: targetMessageId,
            content: text,
            resultMessageId: resultMessageId
        )
    }

    public func fallback(content: ThinkingContent) throws -> String? {
        nil
    }

    public func shouldPush(content: ThinkingContent) throws -> Bool {
        false
    }
}
