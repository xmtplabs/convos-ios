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

    public init(
        databaseWriter: any DatabaseWriter,
        apiClient: any ConvosAPIClientProtocol
    ) {
        self.databaseWriter = databaseWriter
        self.apiClient = apiClient
    }

    public func refresh(force: Bool) async {
        if !force, let last = lastFetchedAt,
           Date().timeIntervalSince(last) < Self.refreshTTL {
            return
        }
        do {
            let balance = try await apiClient.getCreditBalance()
            try await write(balance)
            lastFetchedAt = Date()
        } catch {
            Log.error("Failed to refresh credit balance from backend: \(error)")
        }
    }

    private func write(_ balance: CreditBalance) async throws {
        try await databaseWriter.write { db in
            let row: DBCreditBalance = DBCreditBalance(from: balance)
            try row.save(db)
        }
    }
}
