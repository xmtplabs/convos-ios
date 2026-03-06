import Foundation
import GRDB

public struct VaultDeviceWriter: Sendable {
    private let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func save(device: DBVaultDevice) async throws {
        try await dbWriter.write { db in
            try device.save(db)
        }
    }

    public func saveAll(_ devices: [DBVaultDevice]) async throws {
        try await dbWriter.write { db in
            for device in devices {
                try device.save(db)
            }
        }
    }

    public func delete(inboxId: String) async throws {
        _ = try await dbWriter.write { db in
            try DBVaultDevice.deleteOne(db, key: inboxId)
        }
    }

    public func deleteAll() async throws {
        _ = try await dbWriter.write { db in
            try DBVaultDevice.deleteAll(db)
        }
    }

    public func replaceAll(_ devices: [DBVaultDevice]) async throws {
        try await dbWriter.write { db in
            try DBVaultDevice.deleteAll(db)
            for device in devices {
                try device.save(db)
            }
        }
    }
}
