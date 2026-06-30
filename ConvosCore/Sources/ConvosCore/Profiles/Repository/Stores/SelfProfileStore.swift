import Foundation
import GRDB

/// Persistence for the current user's canonical identity (`DBSelfProfile`).
/// Single-row: there is one self profile per install. Thin round-trips only.
///
/// Not wired into the app yet; introduced ahead of `ProfilesRepository`.
protocol SelfProfileStoreProtocol: Sendable {
    func save(_ profile: DBSelfProfile) async throws
    func load() async throws -> DBSelfProfile?
    func clear() async throws
}

final class GRDBSelfProfileStore: SelfProfileStoreProtocol {
    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader

    init(databaseWriter: any DatabaseWriter, databaseReader: any DatabaseReader) {
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
    }

    func save(_ profile: DBSelfProfile) async throws {
        try await databaseWriter.write { db in
            try profile.save(db)
        }
    }

    func load() async throws -> DBSelfProfile? {
        try await databaseReader.read { db in
            try DBSelfProfile.fetchOne(db)
        }
    }

    func clear() async throws {
        try await databaseWriter.write { db in
            _ = try DBSelfProfile.deleteAll(db)
        }
    }
}

actor InMemorySelfProfileStore: SelfProfileStoreProtocol {
    private var current: DBSelfProfile?

    func save(_ profile: DBSelfProfile) {
        current = profile
    }

    func load() -> DBSelfProfile? {
        current
    }

    func clear() {
        current = nil
    }
}
