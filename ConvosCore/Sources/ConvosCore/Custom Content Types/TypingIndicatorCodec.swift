import Foundation
@preconcurrency import XMTPiOS

public struct TypingIndicatorContent: Codable, Sendable {
    public let isTyping: Bool

    public init(isTyping: Bool) {
        self.isTyping = isTyping
    }
}

public let ContentTypeTypingIndicator = ContentTypeID(
    authorityID: "convos.org",
    typeID: "typing_indicator",
    versionMajor: 1,
    versionMinor: 0
)

public enum TypingIndicatorCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "TypingIndicator content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for TypingIndicator"
        }
    }
}

public struct TypingIndicatorCodec: ContentCodec {
    public typealias T = TypingIndicatorContent

    public var contentType: ContentTypeID = ContentTypeTypingIndicator

    public init() {}

    public func encode(content: TypingIndicatorContent) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeTypingIndicator
        encodedContent.content = try JSONEncoder().encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> TypingIndicatorContent {
        guard !content.content.isEmpty else {
            throw TypingIndicatorCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(TypingIndicatorContent.self, from: content.content)
        } catch {
            throw TypingIndicatorCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: TypingIndicatorContent) throws -> String? {
        nil
    }

    public func shouldPush(content: TypingIndicatorContent) throws -> Bool {
        false
    }
}
