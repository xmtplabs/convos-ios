import Foundation
import GRDB

public struct DBVaultDevice: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName: String = "vaultDevice"

    public var inboxId: String
    public var name: String
    public var isCurrentDevice: Bool
    public var addedAt: Date

    public init(inboxId: String, name: String, isCurrentDevice: Bool, addedAt: Date = Date()) {
        self.inboxId = inboxId
        self.name = name
        self.isCurrentDevice = isCurrentDevice
        self.addedAt = addedAt
    }

    public enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let name: Column = Column(CodingKeys.name)
        static let isCurrentDevice: Column = Column(CodingKeys.isCurrentDevice)
        static let addedAt: Column = Column(CodingKeys.addedAt)
    }
}
