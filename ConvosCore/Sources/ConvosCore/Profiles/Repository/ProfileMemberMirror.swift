import Foundation
import GRDB

/// Transition bridge that keeps the canonical profile stores in sync with the
/// legacy per-conversation `memberProfile` table, before the direct sync seam
/// lands at cutover. Observes `memberProfile` and re-runs the idempotent
/// backfill mirror on each change, so `DBProfile` / `DBProfileAvatar` track the
/// resolved identity the app currently renders.
///
/// This is intentionally temporary: once `StreamProcessor` writes profile events
/// directly and `memberProfile` is removed, the mirror is deleted.
actor ProfileMemberMirror {
    private let databaseReader: any DatabaseReader
    private let profileStore: any ProfileStoreProtocol
    private let selfProfileStore: any SelfProfileStoreProtocol
    private let selfInboxIdProvider: @Sendable () async -> String?

    private var observationTask: Task<Void, Never>?
    private var cachedSelfInboxId: String?

    init(
        databaseReader: any DatabaseReader,
        profileStore: any ProfileStoreProtocol,
        selfProfileStore: any SelfProfileStoreProtocol,
        selfInboxIdProvider: @escaping @Sendable () async -> String?
    ) {
        self.databaseReader = databaseReader
        self.profileStore = profileStore
        self.selfProfileStore = selfProfileStore
        self.selfInboxIdProvider = selfInboxIdProvider
    }

    func start() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            await self?.observe()
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    private func observe() async {
        let dbReader = databaseReader
        let stream = ValueObservation
            .tracking { db in
                try DBMemberProfile.fetchAll(db)
            }
            // Only re-mirror when the row set actually changes; an unrelated
            // write to the same tables can re-emit an identical snapshot.
            .removeDuplicates()
            .values(in: dbReader)
        do {
            for try await rows in stream {
                if Task.isCancelled { return }
                await mirror(rows)
            }
        } catch {
            Log.error("ProfileMemberMirror: stream failed: \(error.localizedDescription)")
        }
    }

    private func mirror(_ rows: [DBMemberProfile]) async {
        guard let selfInboxId = await resolveSelfInboxId() else { return }
        let backfill = ProfileBackfill(
            databaseReader: databaseReader,
            profileStore: profileStore,
            selfProfileStore: selfProfileStore,
            selfInboxId: selfInboxId
        )
        do {
            try await backfill.mirror(rows)
        } catch {
            Log.error("ProfileMemberMirror: mirror failed: \(error.localizedDescription)")
        }
    }

    private func resolveSelfInboxId() async -> String? {
        if let cachedSelfInboxId { return cachedSelfInboxId }
        let resolved = await selfInboxIdProvider()
        cachedSelfInboxId = resolved
        return resolved
    }
}
