import Foundation
import GRDB

public protocol ProfileMetadataWriterProtocol: Sendable {
    /// Reads the current user's self-profile metadata map, applies the caller's
    /// mutation closure, and republishes the merged map through
    /// `ProfilesRepository.publishMyProfileMetadata`, which fans it out to every
    /// conversation. The whole read-modify-write runs as one serialized unit so
    /// two callers (e.g. a connections write and a timezone write) can never
    /// interleave and clobber each other's keys.
    ///
    /// `conversationId` and `inboxId` are retained on the signature for existing
    /// callers; the metadata is now global (self-profile) rather than
    /// per-conversation, so they no longer scope the read.
    func updateMetadata(
        conversationId: String,
        inboxId: String,
        update: @escaping @Sendable (inout ProfileMetadata) -> Void
    ) async throws
}

/// Shared serialization choke point for every per-sender
/// `ProfileUpdate.metadata` write.
///
/// The self-profile metadata map is rewritten wholesale on each publish (read
/// existing -> merge key -> publish). Two async tasks in the same process can
/// interleave on this non-atomic read-merge-write: a timezone publish and a
/// `connections` publish both touch the same `selfProfile` row. If they overlap,
/// the later write overwrites the earlier with a stale copy of the key the other
/// task just set -- silent data loss.
///
/// To prevent that, all metadata map writes go through one shared instance of
/// this class. `@MainActor` keeps the bookkeeping on a single actor, and an
/// internal serial task chain makes each `updateMetadata` call run to completion
/// (including its async hops) before the next one starts, so the read-merge-write
/// is atomic across callers.
@MainActor
public final class ProfileMetadataWriter: ProfileMetadataWriterProtocol {
    private let profilesRepository: @Sendable () -> ProfilesRepository
    private let databaseReader: any DatabaseReader

    /// Tail of the serial task chain. Each new call appends itself after the
    /// previous one, so writes never overlap even across `await` suspension
    /// points. Errors are isolated per call: a failure in one write does not
    /// cancel queued writes. Only ever touched inside `updateMetadata`, which is
    /// `@MainActor`-isolated, so the `nonisolated(unsafe)` here only relaxes the
    /// initializer's isolation and never permits an off-actor mutation.
    private nonisolated(unsafe) var tail: Task<Void, Never> = Task {}

    public nonisolated init(
        profilesRepository: @escaping @Sendable () -> ProfilesRepository,
        databaseReader: any DatabaseReader
    ) {
        self.profilesRepository = profilesRepository
        self.databaseReader = databaseReader
    }

    public func updateMetadata(
        conversationId: String,
        inboxId: String,
        update: @escaping @Sendable (inout ProfileMetadata) -> Void
    ) async throws {
        let previous = tail
        let work = Task { @MainActor [profilesRepository, databaseReader] () -> Result<Void, any Error> in
            await previous.value
            do {
                let existing = try await databaseReader.read { db in
                    try DBSelfProfile.fetchOne(db)?.metadata
                }
                var merged: ProfileMetadata = existing ?? [:]
                update(&merged)
                try await profilesRepository().publishMyProfileMetadata(merged.isEmpty ? nil : merged)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        tail = Task { _ = await work.value }
        switch await work.value {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }
}
