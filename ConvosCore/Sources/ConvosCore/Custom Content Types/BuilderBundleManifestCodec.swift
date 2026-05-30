import Foundation
@preconcurrency import XMTPiOS

/// Payload of a `convos.org/builderBundleManifest:1.0` message: the set of
/// XMTP message ids that make up an agent-builder "bundle" (the prompt +
/// attachments that brief a newly-added agent).
///
/// XMTP/MLS has no per-member message visibility, so the only way to hide the
/// brief from human group members is for every client to cooperatively skip
/// rendering it — the same silent-control-message pattern as `ReadReceipt`
/// and `Thinking`. This manifest carries the ids so *all* clients (not just
/// the sender, who has them locally via `AgentBuilderSummary`) can filter the
/// bundle out of the chat. The ids are the prepared XMTP message ids
/// (deterministic, identical across clients), captured from the send path's
/// prepare step before the bundle is published.
public struct BuilderBundleManifest: Codable, Sendable, Equatable {
    public let messageIds: [String]

    public init(messageIds: [String]) {
        self.messageIds = messageIds
    }
}

public let ContentTypeBuilderBundleManifest = ContentTypeID(
    authorityID: "convos.org",
    typeID: "builderBundleManifest",
    versionMajor: 1,
    versionMinor: 0
)

public enum BuilderBundleManifestCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "BuilderBundleManifest content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for BuilderBundleManifest"
        }
    }
}

/// Silent custom content type announcing which messages form an agent-builder
/// bundle so every client can hide them. Never written to the chat history
/// table (it's a control message), never pushes a notification.
public struct BuilderBundleManifestCodec: ContentCodec {
    public typealias T = BuilderBundleManifest

    public var contentType: ContentTypeID = ContentTypeBuilderBundleManifest

    public init() {}

    public func encode(content: BuilderBundleManifest) throws -> EncodedContent {
        var encoded = EncodedContent()
        encoded.type = ContentTypeBuilderBundleManifest
        encoded.content = try JSONEncoder().encode(content)
        return encoded
    }

    public func decode(content: EncodedContent) throws -> BuilderBundleManifest {
        guard !content.content.isEmpty else {
            throw BuilderBundleManifestCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(BuilderBundleManifest.self, from: content.content)
        } catch {
            throw BuilderBundleManifestCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: BuilderBundleManifest) throws -> String? {
        nil
    }

    public func shouldPush(content: BuilderBundleManifest) throws -> Bool {
        false
    }
}
