import Foundation
@preconcurrency import XMTPiOS

/// Snapshot of conversation-level state, broadcast to a group right after a
/// new member is admitted. Lets late-joiners pick up state that was set by
/// silent codecs they couldn't observe (XMTP streams are forward-only).
///
/// `focusSession` mirrors `FocusModeControl` exactly so receivers can treat
/// the embedded block as a virtual `.start` / `.stop` event. Absent means
/// no live focus session at snapshot time.
public struct ConversationSnapshot: Codable, Sendable {
    public struct FocusSession: Codable, Sendable {
        public let sessionId: String
        public let state: FocusModeControl.State
        public let focusedInboxId: String?

        public init(sessionId: String, state: FocusModeControl.State, focusedInboxId: String?) {
            self.sessionId = sessionId
            self.state = state
            self.focusedInboxId = focusedInboxId
        }
    }

    public let focusSession: FocusSession?

    public init(focusSession: FocusSession?) {
        self.focusSession = focusSession
    }
}

public let ContentTypeConversationSnapshot = ContentTypeID(
    authorityID: "convos.org",
    typeID: "conversation_snapshot",
    versionMajor: 1,
    versionMinor: 0
)

public enum ConversationSnapshotCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "ConversationSnapshot content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for ConversationSnapshot"
        }
    }
}

public struct ConversationSnapshotCodec: ContentCodec {
    public typealias T = ConversationSnapshot

    public var contentType: ContentTypeID = ContentTypeConversationSnapshot

    public init() {}

    public func encode(content: ConversationSnapshot) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeConversationSnapshot
        encodedContent.content = try JSONEncoder().encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> ConversationSnapshot {
        guard !content.content.isEmpty else {
            throw ConversationSnapshotCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(ConversationSnapshot.self, from: content.content)
        } catch {
            throw ConversationSnapshotCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: ConversationSnapshot) throws -> String? {
        nil
    }

    public func shouldPush(content: ConversationSnapshot) throws -> Bool {
        false
    }
}
