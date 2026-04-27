import Foundation

/// Single grant entry stored in a member profile's `connections` metadata.
///
/// Shape matches the runtime's expected format exactly. See:
/// `runtime/convos-platform/skills/connections/scripts/connections.mjs`.
public struct ConnectionGrantEntry: Codable, Sendable, Hashable {
    public let id: String                    // grant identifier (grant_…)
    public let senderId: String               // XMTP inbox ID of the user who granted
    public let service: String                // canonical service name, e.g. "google_calendar"
    public let provider: String               // e.g. "composio"
    public let scope: String                  // "conversation" for v0.1
    public let composioEntityId: String
    public let composioConnectionId: String
    public let grantedAt: String              // ISO8601

    public init(
        id: String,
        senderId: String,
        service: String,
        provider: String,
        scope: String = "conversation",
        composioEntityId: String,
        composioConnectionId: String,
        grantedAt: String
    ) {
        self.id = id
        self.senderId = senderId
        self.service = service
        self.provider = provider
        self.scope = scope
        self.composioEntityId = composioEntityId
        self.composioConnectionId = composioConnectionId
        self.grantedAt = grantedAt
    }
}

/// Payload stored as a JSON string on a sender's member profile under the
/// `connections` key. Contains only that sender's grants — each member
/// writes their own profile.
public struct ConnectionsMetadataPayload: Codable, Sendable {
    public let version: Int
    public var grants: [ConnectionGrantEntry]

    public init(version: Int = 1, grants: [ConnectionGrantEntry] = []) {
        self.version = version
        self.grants = grants
    }

    public var isEmpty: Bool {
        grants.isEmpty
    }

    public func toJsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ConnectionsMetadataError.encodingFailed
        }
        return json
    }

    public static func fromJsonString(_ json: String) throws -> ConnectionsMetadataPayload {
        guard let data = json.data(using: .utf8) else {
            throw ConnectionsMetadataError.decodingFailed
        }
        return try JSONDecoder().decode(ConnectionsMetadataPayload.self, from: data)
    }
}

public enum ConnectionsMetadataError: Error {
    case encodingFailed
    case decodingFailed
}
