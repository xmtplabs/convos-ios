import Foundation

// MARK: - Content type

/// Convos-owned mirror of `XMTPiOS.ContentTypeID`.
///
/// The four fields are the XIP-specified authority/type/major/minor
/// tuple. Convos already treats these as plain values; the struct
/// simply removes the libxmtp import from call sites that compare
/// against `ContentTypeText`, `ContentTypeReply`, etc.
public struct MessagingContentType: Hashable, Sendable, Codable {
    public let authorityID: String
    public let typeID: String
    public let versionMajor: Int
    public let versionMinor: Int

    public init(
        authorityID: String,
        typeID: String,
        versionMajor: Int,
        versionMinor: Int
    ) {
        self.authorityID = authorityID
        self.typeID = typeID
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
    }
}

// MARK: - Compression / send options

/// Compression algorithms supported by the wire format.
public enum MessagingCompression: String, Hashable, Sendable, Codable {
    case gzip
    case deflate
}

/// Options passed when sending / preparing a message.
///
/// Fields mirror `XMTPiOS.SendOptions` + `MessageVisibilityOptions.shouldPush`.
public struct MessagingSendOptions: Hashable, Sendable {
    public var contentType: MessagingContentType
    public var compression: MessagingCompression?
    public var shouldPush: Bool

    public init(
        contentType: MessagingContentType,
        compression: MessagingCompression? = nil,
        shouldPush: Bool = true
    ) {
        self.contentType = contentType
        self.compression = compression
        self.shouldPush = shouldPush
    }
}

// MARK: - Encoded content

/// Convos-owned wrapper around the libxmtp protobuf `EncodedContent`.
///
/// Per the audit (§4 "Leave opaque for now"): the bytes contract is the
/// XIP spec, not the libxmtp Swift struct. The adapter is responsible
/// for serialising into / deserialising out of whichever concrete wire
/// format the backing SDK uses.
public struct MessagingEncodedContent: Hashable, Sendable {
    public var type: MessagingContentType
    public var parameters: [String: String]
    public var content: Data
    public var fallback: String?
    public var compression: MessagingCompression?

    public init(
        type: MessagingContentType,
        parameters: [String: String] = [:],
        content: Data,
        fallback: String? = nil,
        compression: MessagingCompression? = nil
    ) {
        self.type = type
        self.parameters = parameters
        self.content = content
        self.fallback = fallback
        self.compression = compression
    }
}

// MARK: - Reaction

/// Convos-owned mirror of the XIP reaction content struct.
///
/// Fields and cases match the `xmtp.org/reaction:1.0` codec. The
/// adapter layer is responsible for round-tripping between this
/// value and the concrete SDK struct (e.g. `XMTPiOS.Reaction`) — see
/// `Storage/XMTP DB Representations/Reaction+DBRepresentation.swift`
/// for the XMTPiOS boundary. Call sites that want the user-visible
/// emoji glyph should go through the `emoji` computed property on
/// `Storage/Models/MessagingReaction+Emoji.swift`.
public struct MessagingReaction: Hashable, Sendable, Codable {
    public enum Action: String, Hashable, Sendable, Codable {
        case added, removed, unknown
    }

    public enum Schema: String, Hashable, Sendable, Codable {
        case unicode, shortcode, custom, unknown
    }

    public let reference: String
    public let referenceInboxId: String?
    public let action: Action
    public let content: String
    public let schema: Schema

    public init(
        reference: String,
        referenceInboxId: String? = nil,
        action: Action,
        content: String,
        schema: Schema
    ) {
        self.reference = reference
        self.referenceInboxId = referenceInboxId
        self.action = action
        self.content = content
        self.schema = schema
    }
}
