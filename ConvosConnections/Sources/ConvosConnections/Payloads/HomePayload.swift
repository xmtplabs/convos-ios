import Foundation

/// Snapshot of the user's HomeKit topology — home names, room counts, accessory counts.
/// `HomeDataSource` emits this on start and on HMHomeManager updates.
///
/// Intentionally coarse: the payload doesn't carry individual accessory state (lights on,
/// lock open, etc.) because that would push the agent into a command-and-control role
/// that's outside the scope of a context-feeder. If that shape is needed later, add a
/// sibling `HomeAccessorySnapshot` payload.
public struct HomePayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let summary: String
    public let homes: [HomeSummary]
    public let capturedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        summary: String,
        homes: [HomeSummary],
        capturedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.homes = homes
        self.capturedAt = capturedAt
    }
}

public struct HomeSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let isPrimary: Bool
    public let roomCount: Int
    public let accessoryCount: Int

    public init(
        id: String,
        name: String,
        isPrimary: Bool,
        roomCount: Int,
        accessoryCount: Int
    ) {
        self.id = id
        self.name = name
        self.isPrimary = isPrimary
        self.roomCount = roomCount
        self.accessoryCount = accessoryCount
    }
}
