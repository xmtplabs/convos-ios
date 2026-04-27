import Foundation

// MARK: - Codec

/// Convos-owned mirror of `XMTPiOS.ContentCodec`.
///
/// The associated `Content` type is the native Swift payload (e.g.
/// `String` for text, `Reply` for replies). Implementations translate
/// between that payload and `MessagingEncodedContent` on the wire.
///
/// Note on conformances: the audit's §3 sketch listed `Hashable` on this
/// protocol, but `Hashable` + `associatedtype` turns it into a PAT that
/// cannot be boxed into `any MessagingCodec` for most useful purposes.
/// The registry here keys codecs by their `MessagingContentType`, so
/// we drop `Hashable` to keep the existential form usable.
public protocol MessagingCodec: Sendable {
    associatedtype Content

    var contentType: MessagingContentType { get }

    func encode(content: Content) throws -> MessagingEncodedContent
    func decode(content: MessagingEncodedContent) throws -> Content
    func fallback(content: Content) throws -> String?
    func shouldPush(content: Content) throws -> Bool
}

// MARK: - Codec registry

/// Per-process registry mapping `MessagingContentType` to a codec.
///
/// Whether this should be per-process (matching XMTPiOS's
/// `Client.codecRegistry` singleton) or per-client (so parallel tests
/// do not collide) is an open question. We keep an actor-based shared
/// singleton because that matches the status quo; making it per-client
/// is trivial once adapters land.
public actor MessagingCodecRegistry {
    public static let shared: MessagingCodecRegistry = MessagingCodecRegistry()

    private var codecs: [MessagingContentType: any MessagingCodec] = [:]

    public init() {}

    public func register<C: MessagingCodec>(_ codec: C) {
        codecs[codec.contentType] = codec
    }

    public func find(for type: MessagingContentType) -> (any MessagingCodec)? {
        codecs[type]
    }

    public func registeredContentTypes() -> [MessagingContentType] {
        Array(codecs.keys)
    }
}
