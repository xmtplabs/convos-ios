import Foundation
import GRDB

public protocol ProfileMetadataWriterProtocol: Sendable {
    /// Reads the sender's current per-conversation metadata map, applies the
    /// caller's mutation closure, and republishes the merged map through
    /// `MyProfileWriter.updateAndPublish`. The whole read-modify-write runs as
    /// one serialized unit so two callers (e.g. a connections write and a
    /// timezone write) can never interleave and clobber each other's keys.
    func updateMetadata(
        conversationId: String,
        inboxId: String,
        update: @escaping @Sendable (inout ProfileMetadata) -> Void
    ) async throws
}

/// Shared serialization choke point for every per-sender
/// `ProfileUpdate.metadata` write.
///
/// The `ProfileUpdate.metadata` map is per-sender, but a publish rewrites the
/// whole merged map for that sender (read existing -> merge key -> publish).
/// Two async tasks in the same process can interleave on this non-atomic
/// read-merge-write: a timezone publish and a `connections` publish both touch
/// the same `DBMemberProfile`. If they overlap, the later write overwrites the
/// earlier with a stale copy of the key the other task just set -- silent data
/// loss.
///
/// To prevent that, all metadata map writes for a given sender/conversation go
/// through one shared instance of this class. `@MainActor` keeps the bookkeeping
/// on a single actor, and an internal serial task chain makes each
/// `updateMetadata` call run to completion (including its async hops) before the
/// next one starts, so the read-merge-write is atomic across callers.
@MainActor
public final class ProfileMetadataWriter: ProfileMetadataWriterProtocol {
    private let myProfileWriter: any MyProfileWriterProtocol
    private let databaseReader: any DatabaseReader

    /// Tail of the serial task chain. Each new call appends itself after the
    /// previous one, so writes never overlap even across `await` suspension
    /// points. Errors are isolated per call: a failure in one write does not
    /// cancel queued writes. Only ever touched inside `updateMetadata`, which is
    /// `@MainActor`-isolated, so the `nonisolated(unsafe)` here only relaxes the
    /// initializer's isolation and never permits an off-actor mutation.
    private nonisolated(unsafe) var tail: Task<Void, Never> = Task {}

    public nonisolated init(
        myProfileWriter: any MyProfileWriterProtocol,
        databaseReader: any DatabaseReader
    ) {
        self.myProfileWriter = myProfileWriter
        self.databaseReader = databaseReader
    }

    public func updateMetadata(
        conversationId: String,
        inboxId: String,
        update: @escaping @Sendable (inout ProfileMetadata) -> Void
    ) async throws {
        let previous = tail
        let work = Task { @MainActor [myProfileWriter, databaseReader] () -> Result<Void, any Error> in
            await previous.value
            do {
                let existing = try await databaseReader.read { db in
                    try DBMemberProfile.fetchOne(
                        db,
                        conversationId: conversationId,
                        inboxId: inboxId
                    )?.metadata
                }
                var merged: ProfileMetadata = existing ?? [:]
                update(&merged)
                try await myProfileWriter.updateAndPublish(
                    metadata: merged.isEmpty ? nil : merged,
                    conversationId: conversationId
                )
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
