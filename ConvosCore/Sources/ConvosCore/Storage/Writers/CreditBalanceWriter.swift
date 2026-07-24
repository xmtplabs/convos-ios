import Foundation
import GRDB
import os

/// Owns the write path for `credit_balance`. Fetches the latest balance from
/// the backend via `GET /v2/accounts/me/credits` and upserts the single row.
/// TTL-debounced so view-appear + scene-becomes-active triggers don't storm
/// the API as the user navigates between credit-displaying surfaces.
public actor CreditBalanceWriter {
    /// Refresh debounce window. Forced refreshes (pull-to-refresh,
    /// post-purchase) bypass it.
    private static let refreshTTL: TimeInterval = 15

    private let databaseWriter: any DatabaseWriter
    private let apiClient: any ConvosAPIClientProtocol
    private var lastFetchedAt: Date?
    private var refreshTask: Task<Bool, Never>?
    /// Bumped by `beginAccountWipe()`. A refresh captures it before the
    /// network await and skips the DB write when it has moved, so a fetch
    /// started for a deleted account can't re-insert that account's
    /// balance after the account-scoped rows were wiped.
    private var epoch: UInt64 = 0
    /// Wipe-in-progress depth, incremented by `beginAccountWipe()` and
    /// decremented by `endAccountWipe()`. While nonzero, every refresh is
    /// a rejected no-op (no HTTP call, no DB write, no TTL stamp), closing
    /// the gap between quiescence and the actual row deletion: a refresh
    /// entering that gap would otherwise capture the already-bumped epoch
    /// and write after the delete. Reference-counted rather than Boolean
    /// because independent wipe flows can overlap - the deletion/local-reset
    /// teardown and the pairing-adoption row wipe both fence through here
    /// without a shared serializer - and the first `endAccountWipe()` of a
    /// Boolean latch would reopen the writer while the other wipe's delete
    /// is still pending. Lock-backed (not actor state) so `endAccountWipe()`
    /// is synchronous and the wipe paths can guarantee it in a `defer` even
    /// when the deletion throws.
    private nonisolated let wipeDepth: OSAllocatedUnfairLock<Int> = .init(initialState: 0)

    public init(
        databaseWriter: any DatabaseWriter,
        apiClient: any ConvosAPIClientProtocol
    ) {
        self.databaseWriter = databaseWriter
        self.apiClient = apiClient
    }

    public func refresh(force: Bool) async {
        guard wipeDepth.withLock({ $0 }) == 0 else { return }
        if let refreshTask {
            _ = await refreshTask.value
            return
        }
        if !force, let last = lastFetchedAt,
           Date().timeIntervalSince(last) < Self.refreshTTL {
            return
        }
        let epochAtStart: UInt64 = epoch
        let task: Task<Bool, Never> = Task { await performRefresh() }
        refreshTask = task
        let didRefresh = await task.value
        refreshTask = nil
        if didRefresh, epoch == epochAtStart {
            lastFetchedAt = Date()
        }
    }

    /// Account-deletion fence, first half. Latches the writer (every
    /// refresh until `endAccountWipe()` is a rejected no-op), invalidates
    /// any in-flight refresh so its DB write is dropped, and waits for it
    /// to settle. Also resets the TTL so the next account's first refresh
    /// isn't debounced against the wiped row. Callers must pair this with
    /// `endAccountWipe()` after the row deletion - in a `defer`, so a
    /// failed wipe can't leave credits refresh permanently disabled.
    public func beginAccountWipe() async {
        wipeDepth.withLock { $0 += 1 }
        epoch += 1
        lastFetchedAt = nil
        if let refreshTask {
            _ = await refreshTask.value
        }
    }

    /// Account-deletion fence, second half: reopens the writer for the
    /// next account once the LAST overlapping wipe has finished (the depth
    /// is clamped at zero so an unpaired end cannot underflow). Synchronous
    /// so wipe paths can call it from `defer`.
    public nonisolated func endAccountWipe() {
        wipeDepth.withLock { $0 = max(0, $0 - 1) }
    }

    private func performRefresh() async -> Bool {
        let epochAtStart: UInt64 = epoch
        do {
            let balance = try await apiClient.getCreditBalance()
            guard epoch == epochAtStart, wipeDepth.withLock({ $0 }) == 0 else { return false }
            try await write(balance)
            return true
        } catch {
            Log.error("Failed to refresh credit balance from backend: \(error)")
            return false
        }
    }

    private func write(_ balance: CreditBalance) async throws {
        try await databaseWriter.write { db in
            let row: DBCreditBalance = DBCreditBalance(from: balance)
            try row.save(db)
        }
    }
}
