import Foundation
@preconcurrency import XMTPiOS

public struct StreamingClear: Codable, Sendable {
    public let sessionId: String
    public let senderInboxId: String
    public let revision: UInt32

    public init(sessionId: String, senderInboxId: String, revision: UInt32) {
        self.sessionId = sessionId
        self.senderInboxId = senderInboxId
        self.revision = revision
    }
}

public let ContentTypeStreamingClear = ContentTypeID(
    authorityID: "convos.org",
    typeID: "streaming_clear",
    versionMajor: 1,
    versionMinor: 0
)

public enum StreamingClearCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "StreamingClear content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for StreamingClear"
        }
    }
}

public struct StreamingClearCodec: ContentCodec {
    public typealias T = StreamingClear

    public var contentType: ContentTypeID = ContentTypeStreamingClear

    public init() {}

    public func encode(content: StreamingClear) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeStreamingClear
        encodedContent.content = try JSONEncoder().encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> StreamingClear {
        guard !content.content.isEmpty else {
            throw StreamingClearCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(StreamingClear.self, from: content.content)
        } catch {
            throw StreamingClearCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: StreamingClear) throws -> String? {
        nil
    }

    public func shouldPush(content: StreamingClear) throws -> Bool {
        false
    }
}
