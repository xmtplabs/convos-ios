import Foundation

public struct ConnectionGrantEntry: Codable, Sendable, Hashable {
    public let id: String
    public let service: String
    public let provider: String
    public let composioEntityId: String
    public let composioConnectionId: String
    public let triggerTypes: [String]

    public init(
        id: String,
        service: String,
        provider: String,
        composioEntityId: String,
        composioConnectionId: String,
        triggerTypes: [String]
    ) {
        self.id = id
        self.service = service
        self.provider = provider
        self.composioEntityId = composioEntityId
        self.composioConnectionId = composioConnectionId
        self.triggerTypes = triggerTypes
    }
}

public struct ConnectionsMetadataPayload: Codable, Sendable {
    private var grants: [String: [ConnectionGrantEntry]]

    public init(grants: [String: [ConnectionGrantEntry]] = [:]) {
        self.grants = grants
    }

    public func entries(forInboxId inboxId: String) -> [ConnectionGrantEntry] {
        grants[inboxId] ?? []
    }

    public mutating func setEntries(_ entries: [ConnectionGrantEntry], forInboxId inboxId: String) {
        if entries.isEmpty {
            grants.removeValue(forKey: inboxId)
        } else {
            grants[inboxId] = entries
        }
    }

    public var isEmpty: Bool {
        grants.isEmpty
    }

    public func toJsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(grants)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ConnectionsMetadataError.encodingFailed
        }
        return json
    }

    public static func fromJsonString(_ json: String) throws -> ConnectionsMetadataPayload {
        guard let data = json.data(using: .utf8) else {
            throw ConnectionsMetadataError.decodingFailed
        }
        let grants = try JSONDecoder().decode([String: [ConnectionGrantEntry]].self, from: data)
        return ConnectionsMetadataPayload(grants: grants)
    }
}

public enum ConnectionsMetadataError: Error {
    case encodingFailed
    case decodingFailed
}
