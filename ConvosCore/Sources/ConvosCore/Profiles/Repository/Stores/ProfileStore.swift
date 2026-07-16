import Foundation
import GRDB

/// Persistence for other people's canonical identity (`DBProfile`) and their
/// per-conversation avatar slots (`DBProfileAvatar`). Thin: round-trips records
/// only. All merge/precedence logic lives in `ProfilesRepository`, and reactive
/// observation is done by the repository via GRDB `ValueObservation`, so this
/// protocol exposes no change stream.
protocol ProfileStoreProtocol: Sendable {
    // Identity
    func saveIdentity(_ profile: DBProfile) async throws
    func identity(inboxId: String) async throws -> DBProfile?
    func identities(inboxIds: [String]) async throws -> [DBProfile]
    func allIdentities() async throws -> [DBProfile]
    /// Saves every row in one write transaction, isolating per-row failures:
    /// a row that cannot be saved is logged and skipped rather than aborting
    /// the batch. For bulk writers (backfill) that must not pay one
    /// transaction per row nor lose the whole batch to one bad row.
    func saveIdentities(_ profiles: [DBProfile]) async throws

    // Avatars
    func saveAvatar(_ avatar: DBProfileAvatar) async throws
    /// Batch analog of `saveAvatar`; see `saveIdentities`. A common per-row
    /// failure here is the conversation FK: a legacy avatar row can reference
    /// a conversation that no longer exists.
    func saveAvatars(_ avatars: [DBProfileAvatar]) async throws
    func avatar(inboxId: String, conversationId: String) async throws -> DBProfileAvatar?
    func avatars(inboxId: String) async throws -> [DBProfileAvatar]
    func avatars(inboxIds: [String]) async throws -> [DBProfileAvatar]
    func allAvatars() async throws -> [DBProfileAvatar]
    func deleteAvatars(conversationId: String) async throws

    // Lifecycle
    func deleteProfile(inboxId: String) async throws
    func deleteAll() async throws
}

final class GRDBProfileStore: ProfileStoreProtocol {
    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader

    init(databaseWriter: any DatabaseWriter, databaseReader: any DatabaseReader) {
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
    }

    func saveIdentity(_ profile: DBProfile) async throws {
        try await databaseWriter.write { db in
            try profile.save(db)
        }
    }

    func saveIdentities(_ profiles: [DBProfile]) async throws {
        guard !profiles.isEmpty else { return }
        try await databaseWriter.write { db in
            for profile in profiles {
                do {
                    try profile.save(db)
                } catch {
                    Log.error("ProfileStore: skipping identity \(profile.inboxId) in batch save: \(error)")
                }
            }
        }
    }

    func identity(inboxId: String) async throws -> DBProfile? {
        try await databaseReader.read { db in
            try DBProfile.fetchOne(db, inboxId: inboxId)
        }
    }

    func identities(inboxIds: [String]) async throws -> [DBProfile] {
        try await databaseReader.read { db in
            try DBProfile.fetchAll(db, inboxIds: inboxIds)
        }
    }

    func allIdentities() async throws -> [DBProfile] {
        try await databaseReader.read { db in
            try DBProfile.fetchAll(db)
        }
    }

    func saveAvatar(_ avatar: DBProfileAvatar) async throws {
        try await databaseWriter.write { db in
            try avatar.save(db)
        }
    }

    func saveAvatars(_ avatars: [DBProfileAvatar]) async throws {
        guard !avatars.isEmpty else { return }
        try await databaseWriter.write { db in
            for avatar in avatars {
                do {
                    try avatar.save(db)
                } catch {
                    Log.error("ProfileStore: skipping avatar \(avatar.inboxId)/\(avatar.conversationId) in batch save: \(error)")
                }
            }
        }
    }

    func avatar(inboxId: String, conversationId: String) async throws -> DBProfileAvatar? {
        try await databaseReader.read { db in
            try DBProfileAvatar.fetchOne(db, inboxId: inboxId, conversationId: conversationId)
        }
    }

    func avatars(inboxId: String) async throws -> [DBProfileAvatar] {
        try await databaseReader.read { db in
            try DBProfileAvatar.fetchAll(db, inboxId: inboxId)
        }
    }

    func avatars(inboxIds: [String]) async throws -> [DBProfileAvatar] {
        try await databaseReader.read { db in
            try DBProfileAvatar
                .filter(inboxIds.contains(DBProfileAvatar.Columns.inboxId))
                .fetchAll(db)
        }
    }

    func allAvatars() async throws -> [DBProfileAvatar] {
        try await databaseReader.read { db in
            try DBProfileAvatar.fetchAll(db)
        }
    }

    func deleteAvatars(conversationId: String) async throws {
        try await databaseWriter.write { db in
            _ = try DBProfileAvatar
                .filter(DBProfileAvatar.Columns.conversationId == conversationId)
                .deleteAll(db)
        }
    }

    func deleteProfile(inboxId: String) async throws {
        try await databaseWriter.write { db in
            _ = try DBProfile.deleteOne(db, key: inboxId)
            _ = try DBProfileAvatar
                .filter(DBProfileAvatar.Columns.inboxId == inboxId)
                .deleteAll(db)
        }
    }

    func deleteAll() async throws {
        try await databaseWriter.write { db in
            _ = try DBProfile.deleteAll(db)
            _ = try DBProfileAvatar.deleteAll(db)
        }
    }
}

actor InMemoryProfileStore: ProfileStoreProtocol {
    private var identitiesByInbox: [String: DBProfile] = [:]
    private var avatarsByKey: [String: DBProfileAvatar] = [:]

    func saveIdentity(_ profile: DBProfile) {
        identitiesByInbox[profile.inboxId] = profile
    }

    func saveIdentities(_ profiles: [DBProfile]) {
        for profile in profiles {
            identitiesByInbox[profile.inboxId] = profile
        }
    }

    func identity(inboxId: String) -> DBProfile? {
        identitiesByInbox[inboxId]
    }

    func identities(inboxIds: [String]) -> [DBProfile] {
        inboxIds.compactMap { identitiesByInbox[$0] }
    }

    func allIdentities() -> [DBProfile] {
        Array(identitiesByInbox.values)
    }

    func saveAvatar(_ avatar: DBProfileAvatar) {
        avatarsByKey[avatarKey(avatar.inboxId, avatar.conversationId)] = avatar
    }

    func saveAvatars(_ avatars: [DBProfileAvatar]) {
        for avatar in avatars {
            avatarsByKey[avatarKey(avatar.inboxId, avatar.conversationId)] = avatar
        }
    }

    func avatar(inboxId: String, conversationId: String) -> DBProfileAvatar? {
        avatarsByKey[avatarKey(inboxId, conversationId)]
    }

    func avatars(inboxId: String) -> [DBProfileAvatar] {
        avatarsByKey.values.filter { $0.inboxId == inboxId }
    }

    func avatars(inboxIds: [String]) -> [DBProfileAvatar] {
        let wanted = Set(inboxIds)
        return avatarsByKey.values.filter { wanted.contains($0.inboxId) }
    }

    func allAvatars() -> [DBProfileAvatar] {
        Array(avatarsByKey.values)
    }

    func deleteAvatars(conversationId: String) {
        for entry in avatarsByKey where entry.value.conversationId == conversationId {
            avatarsByKey[entry.key] = nil
        }
    }

    func deleteProfile(inboxId: String) {
        identitiesByInbox[inboxId] = nil
        for entry in avatarsByKey where entry.value.inboxId == inboxId {
            avatarsByKey[entry.key] = nil
        }
    }

    func deleteAll() {
        identitiesByInbox.removeAll()
        avatarsByKey.removeAll()
    }

    private func avatarKey(_ inboxId: String, _ conversationId: String) -> String {
        "\(inboxId)|\(conversationId)"
    }
}
