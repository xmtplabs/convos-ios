import Foundation
@preconcurrency import XMTPiOS

/// Invisible signal sent into a conversation the moment the user is ready to
/// use it (the claimed warm-cache conversation is committed visible). The
/// default agent that was pre-added to the conversation joins with its
/// greeting suppressed; this message is its cue to introduce itself. Never
/// rendered, never persisted, never pushed.
public struct ConversationReadyContent: Codable, Sendable {
    public let version: Int

    public init(version: Int = 1) {
        self.version = version
    }
}

public let ContentTypeConversationReady = ContentTypeID(
    authorityID: "convos.org",
    typeID: "conversation_ready",
    versionMajor: 1,
    versionMinor: 0
)

public enum ConversationReadyCodecError: Error {
    case emptyContent
    case invalidJSONFormat
}

public struct ConversationReadyCodec: ContentCodec {
    public typealias T = ConversationReadyContent

    public var contentType: ContentTypeID = ContentTypeConversationReady

    public init() {}

    public func encode(content: ConversationReadyContent) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeConversationReady
        encodedContent.content = try JSONEncoder().encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> ConversationReadyContent {
        guard !content.content.isEmpty else {
            throw ConversationReadyCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(ConversationReadyContent.self, from: content.content)
        } catch {
            throw ConversationReadyCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: ConversationReadyContent) throws -> String? {
        nil
    }

    public func shouldPush(content: ConversationReadyContent) throws -> Bool {
        false
    }
}
