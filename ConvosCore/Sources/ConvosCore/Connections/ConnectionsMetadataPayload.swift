import Foundation

/// Single grant entry stored in XMTP conversation metadata.
///
/// Shape matches the runtime's expected format exactly. See:
/// `runtime/convos-platform/skills/connections/scripts/connections.mjs`.
public struct ConnectionGrantEntry: Codable, Sendable, Hashable {
    public let id: String                    // grant identifier (grant_…)
    public let senderId: String               // XMTP inbox ID of the user who granted
    public let service: String                // e.g. "google_calendar"
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

    /// Entries owned by a given sender (XMTP inbox ID).
    public func entries(forSenderId senderId: String) -> [ConnectionGrantEntry] {
        grants.filter { $0.senderId == senderId }
    }

    /// Replaces this sender's entries, leaving everyone else's grants untouched.
    public mutating func setEntries(
        _ entries: [ConnectionGrantEntry],
        forSenderId senderId: String
    ) {
        grants.removeAll { $0.senderId == senderId }
        grants.append(contentsOf: entries)
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
