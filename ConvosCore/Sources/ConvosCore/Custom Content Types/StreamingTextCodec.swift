import Foundation
@preconcurrency import XMTPiOS

public struct StreamingText: Codable, Sendable {
    public let sessionId: String
    public let senderInboxId: String
    public let revision: UInt32
    public let text: String

    public init(sessionId: String, senderInboxId: String, revision: UInt32, text: String) {
        self.sessionId = sessionId
        self.senderInboxId = senderInboxId
        self.revision = revision
        self.text = text
    }
}

public let ContentTypeStreamingText = ContentTypeID(
    authorityID: "convos.org",
    typeID: "streaming_text",
    versionMajor: 1,
    versionMinor: 0
)

public enum StreamingTextCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "StreamingText content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for StreamingText"
        }
    }
}

public struct StreamingTextCodec: ContentCodec {
    public typealias T = StreamingText

    public var contentType: ContentTypeID = ContentTypeStreamingText

    public init() {}

    public func encode(content: StreamingText) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeStreamingText
        encodedContent.content = try JSONEncoder().encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> StreamingText {
        guard !content.content.isEmpty else {
            throw StreamingTextCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(StreamingText.self, from: content.content)
        } catch {
            throw StreamingTextCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: StreamingText) throws -> String? {
        nil
    }

    public func shouldPush(content: StreamingText) throws -> Bool {
        false
    }
}
