import Foundation
import GRDB

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
    /// Bumped by `prepareForAccountWipe()`. A refresh captures it before
    /// the network await and skips the DB write when it has moved, so a
    /// fetch started for a deleted account can't re-insert that account's
    /// balance after the account-scoped rows were wiped.
    private var epoch: UInt64 = 0

    public init(
        databaseWriter: any DatabaseWriter,
        apiClient: any ConvosAPIClientProtocol
    ) {
        self.databaseWriter = databaseWriter
        self.apiClient = apiClient
    }

    public func refresh(force: Bool) async {
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

    /// Account-deletion fence. Invalidates any in-flight refresh (its DB
    /// write is dropped) and waits for one that already passed the epoch
    /// check to finish its write, so the caller can wipe the rows afterwards
    /// knowing no stale balance lands later. Also resets the TTL so the next
    /// account's first refresh isn't debounced against the wiped row.
    public func prepareForAccountWipe() async {
        epoch += 1
        lastFetchedAt = nil
        if let refreshTask {
            _ = await refreshTask.value
        }
    }

    private func performRefresh() async -> Bool {
        let epochAtStart: UInt64 = epoch
        do {
            let balance = try await apiClient.getCreditBalance()
            guard epoch == epochAtStart else { return false }
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
