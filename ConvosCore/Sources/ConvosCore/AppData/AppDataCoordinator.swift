import ConvosAppData
import Foundation

/// The result of enqueueing an appData change: the locally-merged metadata
/// (read-your-writes - the caller sees its change immediately, before the
/// network write lands) and an awaitable publish signal for flows that must
/// not proceed until the change is on the network (invite tag seeding,
/// lock/unlock rotation). Handles are in-memory only: after process death the
/// durable row still flushes, but nothing can await it.
public struct AppDataChangeHandle: Sendable {
    public let localMerged: ConversationCustomMetadata
    let changeId: String
    private let waitForPublish: @Sendable (String, TimeInterval?) async throws -> Void

    init(
        localMerged: ConversationCustomMetadata,
        changeId: String,
        waitForPublish: @escaping @Sendable (String, TimeInterval?) async throws -> Void
    ) {
        self.localMerged = localMerged
        self.changeId = changeId
        self.waitForPublish = waitForPublish
    }

    /// Resolves when the change is verified on the network (or already was),
    /// throws when the conversation is gone. A change superseded by a newer
    /// same-domain enqueue resolves when the superseding change lands - the
    /// newer intent folded this one in.
    ///
    /// Pass `timeout` to bound the wait. The reconcile loop retries with capped
    /// backoff and never gives up, so an unbounded wait parks forever while
    /// offline; a user-facing flow (lock/unlock) must not. On timeout the
    /// durable row is untouched - it still publishes later - only this wait is
    /// abandoned with `publishTimedOut`. The wait also honors task
    /// cancellation, so tearing down the awaiting task unparks it instead of
    /// leaking a continuation.
    public func awaitPublished(timeout: TimeInterval? = nil) async throws {
        try await waitForPublish(changeId, timeout)
    }
}

public enum AppDataCoordinatorError: Error {
    /// No sync session is attached (before inbox-ready or after teardown).
    case sessionUnavailable
    /// The change closure emptied a non-empty invite tag; refused pre-persist.
    case clearedInviteTag(conversationId: String)
    /// The conversation was dropped before the change could publish.
    case conversationGone(conversationId: String)
    /// `awaitPublished(timeout:)` gave up waiting. The durable change stays
    /// pending and still publishes; only the caller stopped blocking on it.
    case publishTimedOut
}

/// The durable, merging writer for the appData domains routed through it -
/// `expiry`, `participation`, the `agentDm` marker, invite-tag rotation, and
/// legacy-image cleanup (see `AppDataDomain`). Centralizes what the
/// per-operation `atomicUpdateMetadata` call sites each approximated: one
/// merge policy per domain, one 8 KiB cap, one verify, plus what they lacked -
/// durability across offline/restart, per-subkey merge so no writer clobbers
/// another domain's field, and strict parsing so a corrupt blob backs off
/// instead of being treated as empty and written back (clobber-to-empty).
///
/// Not yet the *only* writer: a few creation-time seeders still write appData
/// directly (`ensureCreatorMetadata`'s tag/emoji, `ensureConversationEmoji`,
/// `restoreInviteTagIfMissing`) and the profile publisher writes the `profiles`
/// field via `group.updateProfile`. Those touch fields this coordinator never
/// enqueues (`emoji`, `profiles`) or run at a disjoint time from its only
/// overlapping domain (creator tag-seed at creation vs. rotation later), so
/// they do not contend with a coordinator publish today. Folding them in is a
/// tracked follow-up gated on the attach lifecycle (a seeder on the sync path
/// can run before `attach`, which `enqueueChange` requires).
///
/// One idempotent reconcile pass handles first publish, retry-after-failure,
/// foreign-commit re-merge, our own write echoing back, and restart flush:
/// fold every pending row's updater over the fresh network blob; if that's a
/// no-op the intent already landed (clear the rows), otherwise write the merge
/// and verify per row that re-applying its intent to the re-read blob is a
/// no-op. Failures reschedule with capped backoff and never give up; an
/// observed `app_data` commit clears backoff and re-drains.
public actor AppDataCoordinator {
    private let store: any AppDataPendingChangeStoreProtocol
    private let updaters: [AppDataDomain: any AppDataUpdater]
    private let now: @Sendable () -> Date
    private let backoff: PublishBackoff
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var session: (any AppDataSyncSession)?
    private var draining: Bool = false
    private var redrainRequested: Bool = false
    private var retryTimer: Task<Void, Never>?

    /// Rows enqueued by this process that have not reached a terminal state.
    /// Restart-flushed rows from a previous process are absent - no handle can
    /// reference them.
    private var activeChangeIds: Set<String> = []
    /// Superseded change id -> superseding change id, so an old handle's
    /// `awaitPublished` follows the chain to the row that carries its intent.
    private var supersededBy: [String: String] = [:]
    /// Changes dropped because their conversation is gone, by conversation id.
    private var droppedChangeIds: [String: String] = [:]
    /// Insertion order for the two maps above, so a long-lived session can
    /// evict the oldest entries instead of growing them without bound.
    private var supersededOrder: [String] = []
    private var droppedOrder: [String] = []
    /// One parked `awaitPublished` caller, tokened so a timeout or cancellation
    /// can unpark just this waiter without disturbing siblings on the same id.
    private struct PublishWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var waiters: [String: [PublishWaiter]] = [:]

    init(
        store: any AppDataPendingChangeStoreProtocol,
        updaters: [AppDataDomain: any AppDataUpdater] = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        backoff: PublishBackoff = .default,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.store = store
        self.updaters = updaters
        self.now = now
        self.backoff = backoff
        self.sleep = sleep
    }

    // MARK: - Lifecycle

    /// Binds the network session and flushes any rows a previous process left
    /// pending.
    func attach(session: any AppDataSyncSession) async {
        self.session = session
        await drainReadyChanges()
    }

    /// Unbinds the session. Pending rows stay durable; parked waiters stay
    /// parked - awaiting callers share the session's scope.
    func detach() {
        session = nil
        retryTimer?.cancel()
        retryTimer = nil
    }

    // MARK: - Reads

    /// The conversation's appData as this device understands it: the fresh
    /// network blob, strict-parsed (a corrupt blob throws - it is never
    /// mistaken for empty), with every pending local change folded on top
    /// (read-your-writes).
    public func currentAppData(conversationId: String) async throws -> ConversationCustomMetadata {
        guard let session else { throw AppDataCoordinatorError.sessionUnavailable }
        let fresh = try ConversationCustomMetadata.strictParseAppData(
            try await session.readAppData(conversationId: conversationId)
        )
        let pending = try await store.pendingChanges(conversationId: conversationId)
        return fold(pending, over: fresh, conversationId: conversationId)
    }

    // MARK: - Writes

    /// Applies `change` to the current folded state, persists the result as
    /// the domain's durable pending row (superseding an older same-domain
    /// row), and wakes the publish loop. Returns immediately with the locally
    /// merged blob; use the handle's `awaitPublished()` when ordering against
    /// the network matters. Any random value the closure mints is frozen into
    /// the persisted snapshot, so re-merges stay deterministic.
    @discardableResult
    public func enqueueChange(
        conversationId: String,
        domain: AppDataDomain,
        scopeKey: String? = nil,
        change: @Sendable (inout ConversationCustomMetadata) throws -> Void
    ) async throws -> AppDataChangeHandle {
        let folded = try await currentAppData(conversationId: conversationId)
        var working = folded
        try change(&working)

        if !folded.tag.isEmpty, working.tag.isEmpty {
            Log.error("[MetadataDebug] enqueue domain=\(domain.rawValue) refused to clear invite tag for conversationId=\(conversationId)")
            throw AppDataCoordinatorError.clearedInviteTag(conversationId: conversationId)
        }
        try Self.enforceByteLimit(working)

        let snapshot = try working.serializedData()
        let timestamp = now()
        let changeId = UUID().uuidString
        // Registered before the store insert commits, not after this actor
        // resumes: a drain already mid-loop can pick up the freshly-committed
        // row, land it, and resolve waiters during the suspension below. An
        // unregistered id would then be re-registered as active afterward and
        // its awaiting caller would park forever.
        activeChangeIds.insert(changeId)
        let supersededIds: [String]
        do {
            (_, supersededIds) = try await store.enqueueNext { seq in
                DBAppDataPendingChange(
                    id: changeId,
                    seq: seq,
                    conversationId: conversationId,
                    domain: domain.rawValue,
                    scopeKey: scopeKey,
                    snapshot: snapshot,
                    nextAttemptAt: timestamp,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            }
        } catch {
            activeChangeIds.remove(changeId)
            throw error
        }

        // A racing drain may have already resolved the new change while the
        // insert was committing; superseded rows' waiters then get the same
        // outcome instead of transferring to an id that will never resolve.
        let alreadyResolved = !activeChangeIds.contains(changeId)
        for supersededId in supersededIds {
            recordSuperseded(supersededId, by: changeId)
            activeChangeIds.remove(supersededId)
            guard let transferred = waiters.removeValue(forKey: supersededId) else { continue }
            if alreadyResolved {
                let outcome: Result<Void, any Error>
                if let goneConversationId = droppedChangeIds[changeId] {
                    outcome = .failure(AppDataCoordinatorError.conversationGone(conversationId: goneConversationId))
                } else {
                    outcome = .success(())
                }
                for waiter in transferred {
                    waiter.continuation.resume(with: outcome)
                }
            } else {
                waiters[changeId, default: []] += transferred
            }
        }

        kickBackgroundDrain()

        return AppDataChangeHandle(localMerged: working, changeId: changeId) { [weak self] changeId, timeout in
            guard let self else { return }
            try await self.awaitPublished(changeId: changeId, timeout: timeout)
        }
    }

    /// Drops all pending intent for a deleted conversation.
    func deletePendingChanges(conversationId: String) async {
        let rows = (try? await store.pendingChanges(conversationId: conversationId)) ?? []
        try? await store.deleteAll(conversationId: conversationId)
        for row in rows {
            resolveWaiters(
                changeId: row.id,
                with: .failure(AppDataCoordinatorError.conversationGone(conversationId: conversationId)),
                droppedInConversation: conversationId
            )
        }
    }

    // MARK: - Network signal

    /// A GroupUpdated commit touching `app_data` was observed for this
    /// conversation. The payload is never trusted - the reconcile pass
    /// re-reads the group - so duplicate or self-echo deliveries are harmless:
    /// a self-echo folds to `merged == fresh` and clears without writing.
    func onAppDataCommitObserved(conversationId: String) async {
        try? await store.resetBackoff(conversationId: conversationId, now: now())
        kickBackgroundDrain()
    }

    // MARK: - Waiting

    private func awaitPublished(changeId: String, timeout: TimeInterval?) async throws {
        var resolved = changeId
        while let superseding = supersededBy[resolved] {
            resolved = superseding
        }
        if let conversationId = droppedChangeIds[resolved] {
            throw AppDataCoordinatorError.conversationGone(conversationId: conversationId)
        }
        guard activeChangeIds.contains(resolved) else { return }
        let waitId = resolved
        let waiterId = UUID()

        // Bound the wait so an offline caller does not park forever - the
        // reconcile loop retries with capped backoff and never gives up. The
        // durable row is left untouched; only this wait is abandoned.
        let sleep = self.sleep
        let timeoutTask: Task<Void, Never>? = timeout.map { seconds in
            Task { [weak self] in
                do {
                    try await sleep(seconds)
                } catch {
                    return
                }
                await self?.failWaiter(waitId: waitId, waiterId: waiterId, with: AppDataCoordinatorError.publishTimedOut)
            }
        }
        defer { timeoutTask?.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[waitId, default: []].append(PublishWaiter(id: waiterId, continuation: continuation))
            }
        } onCancel: {
            Task { await self.failWaiter(waitId: waitId, waiterId: waiterId, with: CancellationError()) }
        }
    }

    /// Unparks a single waiter with a terminal error (timeout or cancellation)
    /// and removes it, leaving the durable row and any sibling waiters intact.
    /// A no-op if that waiter already resolved.
    private func failWaiter(waitId: String, waiterId: UUID, with error: any Error) {
        guard var entries = waiters[waitId],
              let index = entries.firstIndex(where: { $0.id == waiterId }) else {
            return
        }
        let waiter = entries.remove(at: index)
        if entries.isEmpty {
            waiters[waitId] = nil
        } else {
            waiters[waitId] = entries
        }
        waiter.continuation.resume(throwing: error)
    }

    private func resolveWaiters(changeId: String, with result: Result<Void, any Error>, droppedInConversation: String? = nil) {
        activeChangeIds.remove(changeId)
        if let droppedInConversation {
            recordDropped(changeId, conversationId: droppedInConversation)
        }
        guard let entries = waiters.removeValue(forKey: changeId) else { return }
        for waiter in entries {
            waiter.continuation.resume(with: result)
        }
    }

    /// Records a supersede / drop mapping, evicting the oldest entries once the
    /// map exceeds `bookkeepingCap`. Eviction only ever weakens an
    /// `awaitPublished` on an id superseded or dropped thousands of changes ago
    /// - handles are awaited promptly or discarded, so in practice the awaited
    /// id is always still present. An evicted lookup resolves as success rather
    /// than following the chain, an acceptable degradation at this cap.
    private func recordSuperseded(_ supersededId: String, by supersedingId: String) {
        if supersededBy[supersededId] == nil {
            supersededOrder.append(supersededId)
        }
        supersededBy[supersededId] = supersedingId
        evictOldest(from: &supersededBy, order: &supersededOrder)
    }

    private func recordDropped(_ changeId: String, conversationId: String) {
        if droppedChangeIds[changeId] == nil {
            droppedOrder.append(changeId)
        }
        droppedChangeIds[changeId] = conversationId
        evictOldest(from: &droppedChangeIds, order: &droppedOrder)
    }

    private func evictOldest(from map: inout [String: String], order: inout [String]) {
        guard order.count > Constant.bookkeepingCap else { return }
        let overflow = order.count - Constant.bookkeepingCap
        for staleId in order.prefix(overflow) {
            map[staleId] = nil
        }
        order.removeFirst(overflow)
    }

    // MARK: - Drain loop

    private func kickBackgroundDrain() {
        Task { await drainReadyChanges() }
    }

    func drainReadyChanges() async {
        // A drain requested while one is running must not be dropped: the
        // running drain's scan may predate the requester's enqueue. Flag it
        // and let the running drain loop once more.
        if draining {
            redrainRequested = true
            return
        }
        guard session != nil else { return }
        draining = true
        defer { draining = false }
        repeat {
            redrainRequested = false
            // A pass that hit a store error stops without re-arming the
            // timer: a failing row's past deadline would arm a zero-delay
            // timer that immediately re-enters the failing pass, a hot loop.
            // The next external trigger (enqueue, commit, attach) retries.
            guard await drainPass() else { return }
            await armRetryTimer()
        } while redrainRequested
    }

    /// Runs reconcile passes until no conversation is ready. Returns false
    /// when a store error stopped the pass early.
    private func drainPass() async -> Bool {
        while true {
            guard session != nil else { return true }
            let conversationId: String?
            do {
                conversationId = try await store.nextReadyConversation(now: now())
            } catch {
                Log.error("AppDataCoordinator: failed to fetch next ready conversation, stopping drain: \(error)")
                return false
            }
            guard let conversationId else { return true }
            // Reconcile guarantees progress: every path either deletes the
            // conversation's rows or pushes their nextAttemptAt into the
            // future, so this loop cannot spin on one conversation.
            guard await reconcile(conversationId) else { return false }
        }
    }

    /// The outcome of a reconcile stage: `.stop` halts the drain (a store
    /// error), `.doneConversation` finishes this conversation without an error,
    /// and `.proceed` carries the values the next stage needs.
    private enum ReconcileStep<Value> {
        case stop
        case doneConversation
        case proceed(Value)
    }

    /// The one idempotent publish algorithm. Returns false only when a store
    /// error prevented recording an outcome (the drain must stop).
    private func reconcile(_ conversationId: String) async -> Bool {
        guard session != nil else { return true }
        let rows: [DBAppDataPendingChange]
        switch await loadPublishableRows(conversationId: conversationId) {
        case .stop: return false
        case .doneConversation: return true
        case .proceed(let value): rows = value
        }

        let fresh: ConversationCustomMetadata
        switch await fetchFresh(conversationId: conversationId, rows: rows) {
        case .stop: return false
        case .doneConversation: return true
        case .proceed(let value): fresh = value
        }

        let merged = fold(rows, over: fresh, conversationId: conversationId)
        if merged == fresh {
            return await clearLandedRows(rows, conversationId: conversationId)
        }
        return await publishMerged(rows, fresh: fresh, merged: merged, conversationId: conversationId)
    }

    /// Loads the conversation's pending rows and reschedules any that carry an
    /// unknown domain or undecodable snapshot (no merge rule).
    private func loadPublishableRows(conversationId: String) async -> ReconcileStep<[DBAppDataPendingChange]> {
        let allRows: [DBAppDataPendingChange]
        do {
            allRows = try await store.pendingChanges(conversationId: conversationId)
        } catch {
            Log.error("AppDataCoordinator: failed to load pending rows for \(conversationId): \(error)")
            return .stop
        }
        guard !allRows.isEmpty else { return .doneConversation }

        let (rows, unmergeable) = partitionMergeable(allRows)
        if !unmergeable.isEmpty {
            Log.warning("AppDataCoordinator: skipping \(unmergeable.count) unmergeable row(s) for \(conversationId)")
            guard await reschedule(unmergeable, conversationId: conversationId, error: nil) else { return .stop }
        }
        return rows.isEmpty ? .doneConversation : .proceed(rows)
    }

    /// Reads and strict-parses the fresh network blob. A gone conversation
    /// drops the rows; a corrupt (never empty) blob or read error backs off.
    private func fetchFresh(conversationId: String, rows: [DBAppDataPendingChange]) async -> ReconcileStep<ConversationCustomMetadata> {
        guard let session else { return .doneConversation }
        let freshString: String?
        do {
            freshString = try await session.readAppData(conversationId: conversationId)
        } catch AppDataSyncSessionError.conversationNotFound {
            return await dropGoneConversation(rows, conversationId: conversationId)
        } catch {
            return await reschedule(rows, conversationId: conversationId, error: error) ? .doneConversation : .stop
        }

        do {
            return .proceed(try ConversationCustomMetadata.strictParseAppData(freshString))
        } catch {
            // A corrupt network blob is never treated as empty - writing over
            // it would clobber every domain to defaults. Back off and wait for
            // the blob to change (or a commit signal).
            Log.error("AppDataCoordinator: corrupt appData blob for \(conversationId), backing off: \(error)")
            return await reschedule(rows, conversationId: conversationId, error: error) ? .doneConversation : .stop
        }
    }

    private func dropGoneConversation(_ rows: [DBAppDataPendingChange], conversationId: String) async -> ReconcileStep<ConversationCustomMetadata> {
        Log.warning("AppDataCoordinator: conversation \(conversationId) gone, dropping \(rows.count) pending change(s)")
        do {
            try await store.delete(ids: rows.map(\.id))
        } catch {
            Log.error("AppDataCoordinator: failed to drop rows for gone conversation \(conversationId): \(error)")
            return .stop
        }
        for row in rows {
            resolveWaiters(
                changeId: row.id,
                with: .failure(AppDataCoordinatorError.conversationGone(conversationId: conversationId)),
                droppedInConversation: conversationId
            )
        }
        return .doneConversation
    }

    /// Self-echo path: the fresh blob already carries our intent, so clear the
    /// rows and resolve waiters without a write.
    private func clearLandedRows(_ rows: [DBAppDataPendingChange], conversationId: String) async -> Bool {
        do {
            try await store.delete(ids: rows.map(\.id))
        } catch {
            Log.error("AppDataCoordinator: failed to clear landed rows for \(conversationId): \(error)")
            return false
        }
        for row in rows {
            resolveWaiters(changeId: row.id, with: .success(()))
        }
        return true
    }

    /// Encodes and writes the merged blob (guarding the tag and byte limit),
    /// then verifies per row that re-applying its intent to the re-read blob is
    /// a no-op.
    private func publishMerged(
        _ rows: [DBAppDataPendingChange],
        fresh: ConversationCustomMetadata,
        merged: ConversationCustomMetadata,
        conversationId: String
    ) async -> Bool {
        let domains = rows.map(\.domain).joined(separator: ",")
        if !fresh.tag.isEmpty, merged.tag.isEmpty {
            Log.error("[MetadataDebug] reconcile refusing to clear invite tag for conversationId=\(conversationId) domains=\(domains)")
            return await reschedule(rows, conversationId: conversationId, error: AppDataCoordinatorError.clearedInviteTag(conversationId: conversationId))
        }

        let encoded: String
        do {
            try Self.enforceByteLimit(merged)
            encoded = try merged.toCompactString()
        } catch {
            // Over the byte limit after merging: the fresh blob may shrink
            // (e.g. a peer trims profiles), so back off rather than give up.
            Log.error("AppDataCoordinator: merged blob for \(conversationId) not writable, backing off: \(error)")
            return await reschedule(rows, conversationId: conversationId, error: error)
        }

        Log.info("[MetadataDebug] publish conversationId=\(conversationId) domains=\(domains) beforeTag=\(fresh.tag) afterTag=\(merged.tag) bytes=\(encoded.utf8.count)")

        guard let session else { return true }
        do {
            try await session.writeAppData(conversationId: conversationId, appData: encoded)
        } catch {
            return await reschedule(rows, conversationId: conversationId, error: error)
        }

        let reread: ConversationCustomMetadata
        do {
            reread = try ConversationCustomMetadata.strictParseAppData(
                try await session.readAppData(conversationId: conversationId)
            )
        } catch {
            Log.error("AppDataCoordinator: failed to re-read appData for \(conversationId) after write: \(error)")
            return await reschedule(rows, conversationId: conversationId, error: error)
        }
        return await recordVerification(rows, reread: reread, conversationId: conversationId)
    }

    /// A row landed exactly when re-applying its stored intent to the re-read
    /// blob is a no-op (updater idempotence is the verification). Landed rows
    /// clear and resolve; lost rows back off for another pass.
    private func recordVerification(
        _ rows: [DBAppDataPendingChange],
        reread: ConversationCustomMetadata,
        conversationId: String
    ) async -> Bool {
        var landedRows: [DBAppDataPendingChange] = []
        var lostRows: [DBAppDataPendingChange] = []
        for row in rows {
            if apply(row, to: reread, conversationId: conversationId) == reread {
                landedRows.append(row)
            } else {
                lostRows.append(row)
            }
        }

        do {
            try await store.delete(ids: landedRows.map(\.id))
        } catch {
            Log.error("AppDataCoordinator: failed to clear landed rows for \(conversationId): \(error)")
            return false
        }
        for row in landedRows {
            resolveWaiters(changeId: row.id, with: .success(()))
        }
        guard lostRows.isEmpty else {
            Log.warning("[MetadataDebug] publish lost race conversationId=\(conversationId) domains=\(lostRows.map(\.domain).joined(separator: ","))")
            return await reschedule(lostRows, conversationId: conversationId, error: nil)
        }
        return true
    }

    /// Pushes rows to their next backoff deadline. Returns false only when
    /// the store write itself failed.
    private func reschedule(_ rows: [DBAppDataPendingChange], conversationId: String, error: (any Error)?) async -> Bool {
        let timestamp = now()
        for row in rows {
            let attempt = row.attemptCount + 1
            let nextAttemptAt = timestamp.addingTimeInterval(backoff.delay(forAttempt: attempt))
            do {
                try await store.reschedule(
                    ids: [row.id],
                    attemptCount: attempt,
                    nextAttemptAt: nextAttemptAt,
                    lastError: error.map { String(describing: $0) },
                    updatedAt: timestamp
                )
            } catch {
                Log.error("AppDataCoordinator: failed to reschedule row \(row.id) for \(conversationId): \(error)")
                return false
            }
        }
        return true
    }

    /// Schedules the next drain for the earliest backoff deadline, so retries
    /// fire without waiting for an external trigger.
    private func armRetryTimer() async {
        retryTimer?.cancel()
        retryTimer = nil
        guard session != nil else { return }
        guard let earliest = try? await store.earliestNextAttempt() else { return }
        let delay = max(0, earliest.timeIntervalSince(now()))
        retryTimer = Task { [sleep] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            await self.drainReadyChanges()
        }
    }

    // MARK: - Merging

    private func fold(
        _ rows: [DBAppDataPendingChange],
        over fresh: ConversationCustomMetadata,
        conversationId: String
    ) -> ConversationCustomMetadata {
        rows.reduce(fresh) { accumulated, row in
            apply(row, to: accumulated, conversationId: conversationId)
        }
    }

    private func apply(
        _ row: DBAppDataPendingChange,
        to current: ConversationCustomMetadata,
        conversationId: String
    ) -> ConversationCustomMetadata {
        guard let domain = AppDataDomain(rawValue: row.domain),
              let updater = updaters[domain],
              let snapshot = try? ConversationCustomMetadata(serializedBytes: row.snapshot) else {
            return current
        }
        return updater.onAppDataMerge(
            conversationId: conversationId,
            scopeKey: row.scopeKey,
            current: current,
            previousChanged: snapshot
        )
    }

    private func partitionMergeable(
        _ rows: [DBAppDataPendingChange]
    ) -> (mergeable: [DBAppDataPendingChange], unmergeable: [DBAppDataPendingChange]) {
        var mergeable: [DBAppDataPendingChange] = []
        var unmergeable: [DBAppDataPendingChange] = []
        for row in rows {
            let hasUpdater = AppDataDomain(rawValue: row.domain).flatMap { updaters[$0] } != nil
            let decodes = (try? ConversationCustomMetadata(serializedBytes: row.snapshot)) != nil
            if hasUpdater && decodes {
                mergeable.append(row)
            } else {
                unmergeable.append(row)
            }
        }
        return (mergeable, unmergeable)
    }

    private static func enforceByteLimit(_ metadata: ConversationCustomMetadata) throws {
        let encoded = try metadata.toCompactString()
        let byteCount = encoded.lengthOfBytes(using: .utf8)
        guard byteCount <= ConversationCustomMetadata.appDataByteLimit else {
            throw ConversationCustomMetadataError.appDataLimitExceeded(
                limit: ConversationCustomMetadata.appDataByteLimit,
                actualSize: byteCount
            )
        }
    }

    private enum Constant {
        /// Cap on each `awaitPublished` bookkeeping map before oldest-eviction.
        static let bookkeepingCap: Int = 4_096
    }
}
