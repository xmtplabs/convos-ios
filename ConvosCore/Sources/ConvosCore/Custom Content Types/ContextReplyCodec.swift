import Foundation
import XMTPiOS

/// The widget a `ContextReply` is associated with. Mirrors the web bridge's
/// `WidgetRef` (title + description) plus the widget id from the
/// `replyToWidget(id:widget:)` call. Kept free of any bridge types so
/// ConvosCore stays platform-independent.
public struct ContextReplyContext: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let description: String

    public init(id: String, title: String, description: String) {
        self.id = id
        self.title = title
        self.description = description
    }
}

/// A message the user composed while replying to a widget. Works like XMTP's
/// `Reply`: it wraps any kind of content the user can send (text, attachment,
/// remote attachment, ...) and associates it with the widget `context` instead
/// of a parent message.
public struct ContextReply {
    public var context: ContextReplyContext
    public var content: Any
    public var contentType: ContentTypeID

    public init(context: ContextReplyContext, content: Any, contentType: ContentTypeID) {
        self.context = context
        self.content = content
        self.contentType = contentType
    }
}

public let ContentTypeContextReply = ContentTypeID(authorityID: "convos.org", typeID: "context_reply", versionMajor: 1, versionMinor: 0)

public enum ContextReplyCodecError: Error, LocalizedError {
    case missingContext
    case invalidContext
    case unsupportedNestedContentType(ContentTypeID)
    case mismatchedNestedContent

    public var errorDescription: String? {
        switch self {
        case .missingContext:
            return "ContextReply is missing its widget context"
        case .invalidContext:
            return "ContextReply widget context could not be decoded"
        case .unsupportedNestedContentType(let type):
            return "ContextReply cannot wrap content type \(type.authorityID)/\(type.typeID)"
        case .mismatchedNestedContent:
            return "ContextReply nested content did not match its declared content type"
        }
    }
}

public struct ContextReplyCodec: ContentCodec {
    public typealias T = ContextReply

    public var contentType: ContentTypeID = ContentTypeContextReply

    public init() {}

    public func encode(content contextReply: ContextReply) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeContextReply
        encodedContent.parameters["context"] = try Self.encodeContext(contextReply.context)
        encodedContent.parameters["contentType"] = contextReply.contentType.description
        encodedContent.content = try Self.encodeNested(
            content: contextReply.content,
            contentType: contextReply.contentType
        ).serializedData()
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> ContextReply {
        guard let contextParameter = content.parameters["context"] else {
            throw ContextReplyCodecError.missingContext
        }
        let context = try Self.decodeContext(contextParameter)

        let nestedEncoded = try EncodedContent(serializedData: content.content)
        let nested = try Self.decodeNested(nestedEncoded)
        return ContextReply(context: context, content: nested.content, contentType: nested.contentType)
    }

    public func fallback(content contextReply: ContextReply) throws -> String? {
        "Replied to \"\(contextReply.context.title)\""
    }

    public func shouldPush(content _: ContextReply) throws -> Bool {
        true
    }

    // MARK: - Context (de)serialization

    private static func encodeContext(_ context: ContextReplyContext) throws -> String {
        let data = try JSONEncoder().encode(context)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ContextReplyCodecError.invalidContext
        }
        return json
    }

    private static func decodeContext(_ parameter: String) throws -> ContextReplyContext {
        guard let data = parameter.data(using: .utf8) else {
            throw ContextReplyCodecError.invalidContext
        }
        do {
            return try JSONDecoder().decode(ContextReplyContext.self, from: data)
        } catch {
            throw ContextReplyCodecError.invalidContext
        }
    }

    // MARK: - Nested content (de)serialization

    // `Client.codecRegistry` is internal to XMTPiOS, so the codec dispatches
    // over the same content types replies support (see handleReplyContent in
    // DecodedMessage+DBRepresentation): text and its text-encoded variants
    // (invite, link preview, agent share) plus inline and remote attachments.
    private static func encodeNested(content: Any, contentType: ContentTypeID) throws -> EncodedContent {
        switch contentType {
        case ContentTypeText:
            guard let text = content as? String else {
                throw ContextReplyCodecError.mismatchedNestedContent
            }
            return try TextCodec().encode(content: text)
        case ContentTypeAttachment:
            guard let attachment = content as? Attachment else {
                throw ContextReplyCodecError.mismatchedNestedContent
            }
            return try AttachmentCodec().encode(content: attachment)
        case ContentTypeRemoteAttachment:
            guard let remoteAttachment = content as? RemoteAttachment else {
                throw ContextReplyCodecError.mismatchedNestedContent
            }
            return try RemoteAttachmentCodec().encode(content: remoteAttachment)
        case ContentTypeMultiRemoteAttachment:
            guard let multiRemoteAttachment = content as? MultiRemoteAttachment else {
                throw ContextReplyCodecError.mismatchedNestedContent
            }
            return try MultiRemoteAttachmentCodec().encode(content: multiRemoteAttachment)
        default:
            throw ContextReplyCodecError.unsupportedNestedContentType(contentType)
        }
    }

    private static func decodeNested(_ encoded: EncodedContent) throws -> (content: Any, contentType: ContentTypeID) {
        let nestedType = encoded.type
        switch nestedType {
        case ContentTypeText:
            return (try TextCodec().decode(content: encoded), ContentTypeText)
        case ContentTypeAttachment:
            return (try AttachmentCodec().decode(content: encoded), ContentTypeAttachment)
        case ContentTypeRemoteAttachment:
            return (try RemoteAttachmentCodec().decode(content: encoded), ContentTypeRemoteAttachment)
        case ContentTypeMultiRemoteAttachment:
            return (try MultiRemoteAttachmentCodec().decode(content: encoded), ContentTypeMultiRemoteAttachment)
        default:
            throw ContextReplyCodecError.unsupportedNestedContentType(nestedType)
        }
    }
}
