import ConvosConnections
import Foundation
@preconcurrency import XMTPiOS

public struct ConnectionEvent: Codable, Sendable, Hashable {
    public static let supportedVersion: Int = 1

    public enum Action: String, Codable, Sendable, Hashable {
        case granted
        case revoked
    }

    public let version: Int
    public let providerId: String
    public let action: Action
    /// The verb the event applies to. Optional so older agents and writers that
    /// don't tag events with a capability still decode cleanly; the formatter
    /// falls back to a generic phrase when nil.
    public let capability: ConnectionCapability?
    /// Inbox id of the agent the event concerns. For `.granted` this is the agent
    /// gaining access; for `.revoked` it's the agent losing access. Optional on
    /// the wire so app-level / multi-agent revoke events (where no specific agent
    /// is meaningful — e.g. the user disconnected the underlying OAuth) can
    /// continue to omit it.
    public let grantedToInboxId: String?

    public init(
        version: Int = ConnectionEvent.supportedVersion,
        providerId: String,
        action: Action,
        capability: ConnectionCapability? = nil,
        grantedToInboxId: String? = nil
    ) {
        self.version = version
        self.providerId = providerId
        self.action = action
        self.capability = capability
        self.grantedToInboxId = grantedToInboxId
    }

    private enum CodingKeys: String, CodingKey {
        case version, providerId, action, capability, grantedToInboxId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.providerId = try container.decode(String.self, forKey: .providerId)
        self.action = try container.decode(Action.self, forKey: .action)
        self.capability = try container.decodeIfPresent(ConnectionCapability.self, forKey: .capability)
        self.grantedToInboxId = try container.decodeIfPresent(String.self, forKey: .grantedToInboxId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(providerId, forKey: .providerId)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(capability, forKey: .capability)
        try container.encodeIfPresent(grantedToInboxId, forKey: .grantedToInboxId)
    }
}

public let ContentTypeConnectionEvent = ContentTypeID(
    authorityID: "convos.org",
    typeID: "connection_event",
    versionMajor: 1,
    versionMinor: 0
)

public struct ConnectionEventCodec: ContentCodec {
    public typealias T = ConnectionEvent

    public var contentType: ContentTypeID = ContentTypeConnectionEvent

    public init() {}

    public func encode(content: ConnectionEvent) throws -> EncodedContent {
        var encoded = EncodedContent()
        encoded.type = ContentTypeConnectionEvent
        encoded.content = try JSONEncoder().encode(content)
        return encoded
    }

    public func decode(content: EncodedContent) throws -> ConnectionEvent {
        try JSONDecoder().decode(ConnectionEvent.self, from: content.content)
    }

    public func fallback(content: ConnectionEvent) throws -> String? {
        nil
    }

    public func shouldPush(content: ConnectionEvent) throws -> Bool {
        false
    }
}
