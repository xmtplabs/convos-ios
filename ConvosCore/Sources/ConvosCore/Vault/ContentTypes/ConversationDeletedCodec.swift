import Foundation
@preconcurrency import XMTPiOS

public let ContentTypeConversationDeleted: ContentTypeID = ContentTypeID(
    authorityID: "convos.org",
    typeID: "conversation_deleted",
    versionMajor: 1,
    versionMinor: 0
)

public struct ConversationDeletedContent: Codable, Sendable, Equatable {
    public let inboxId: String
    public let clientId: String
    public let timestamp: Date

    public init(
        inboxId: String,
        clientId: String,
        timestamp: Date = Date()
    ) {
        self.inboxId = inboxId
        self.clientId = clientId
        self.timestamp = timestamp
    }
}

public enum ConversationDeletedCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "ConversationDeleted content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for ConversationDeleted"
        }
    }
}

public struct ConversationDeletedCodec: ContentCodec {
    public typealias T = ConversationDeletedContent

    public var contentType: ContentTypeID = ContentTypeConversationDeleted

    public init() {}

    public func encode(content: ConversationDeletedContent) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeConversationDeleted
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encodedContent.content = try encoder.encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> ConversationDeletedContent {
        guard !content.content.isEmpty else {
            throw ConversationDeletedCodecError.emptyContent
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ConversationDeletedContent.self, from: content.content)
    }

    public func fallback(content: ConversationDeletedContent) throws -> String? {
        "Conversation deleted"
    }

    public func shouldPush(content: ConversationDeletedContent) throws -> Bool {
        false
    }
}
