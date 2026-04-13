import Combine
import Foundation
import GRDB

/// Derived state for the local device's stale-installation status.
///
/// Computed from the set of "used" non-vault inboxes (inboxes that have at least
/// one non-unused conversation) and how many of them are flagged as `isStale = true`.
///
/// Used by the conversations list to drive partial vs full stale UX:
/// - `healthy` — no stale inboxes; normal operation
/// - `partialStale` — some inboxes are revoked but the user still has working ones
/// - `fullStale` — every used inbox has been revoked; the device is effectively dead
public enum StaleDeviceState: Equatable, Sendable {
    case healthy
    case partialStale
    case fullStale

    /// True when the user has at least one working inbox (healthy or partial).
    public var hasUsableInboxes: Bool {
        switch self {
        case .healthy, .partialStale: true
        case .fullStale: false
        }
    }

    /// True when any inbox is stale (partial or full).
    public var hasAnyStaleInboxes: Bool {
        switch self {
        case .healthy: false
        case .partialStale, .fullStale: true
        }
    }
}

/// Repository for fetching inbox data from the database
public struct InboxesRepository {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    /// Publishes the derived `StaleDeviceState` based on the current set of used non-vault inboxes
    /// and which of them are flagged as stale. See `StaleDeviceState` for the semantics.
    public func staleDeviceStatePublisher() -> AnyPublisher<StaleDeviceState, Never> {
        ValueObservation
            .tracking { db in
                let usedSql = """
                    SELECT i.inboxId, i.isStale
                    FROM inbox i
                    WHERE i.isVault = 0
                      AND EXISTS (
                          SELECT 1
                          FROM conversation c
                          WHERE c.inboxId = i.inboxId
                            AND c.isUnused = 0
                      )
                    """
                let rows = try Row.fetchAll(db, sql: usedSql)
                let total = rows.count
                let stale = rows.filter { $0["isStale"] as Bool == true }.count

                if total == 0 || stale == 0 {
                    return StaleDeviceState.healthy
                }
                if stale == total {
                    return StaleDeviceState.fullStale
                }
                return StaleDeviceState.partialStale
            }
            .publisher(in: databaseReader)
            .replaceError(with: StaleDeviceState.healthy)
            .eraseToAnyPublisher()
    }

    /// Publishes `true` when any non-vault inbox is flagged as stale (installation revoked).
    public func anyInboxStalePublisher() -> AnyPublisher<Bool, Never> {
        ValueObservation
            .tracking { db in
                try DBInbox
                    .filter(DBInbox.Columns.isVault == false)
                    .filter(DBInbox.Columns.isStale == true)
                    .fetchCount(db) > 0
            }
            .publisher(in: databaseReader)
            .replaceError(with: false)
            .eraseToAnyPublisher()
    }

    /// Publishes the set of inboxIds that are currently stale.
    public func staleInboxIdsPublisher() -> AnyPublisher<Set<String>, Never> {
        ValueObservation
            .tracking { db in
                let ids = try DBInbox
                    .filter(DBInbox.Columns.isStale == true)
                    .filter(DBInbox.Columns.isVault == false)
                    .select(DBInbox.Columns.inboxId, as: String.self)
                    .fetchAll(db)
                return Set(ids)
            }
            .publisher(in: databaseReader)
            .replaceError(with: Set<String>())
            .eraseToAnyPublisher()
    }

    /// Fetch all inboxes from the database
    public func allInboxes() throws -> [Inbox] {
        try databaseReader.read { db in
            try DBInbox
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    /// Fetch a specific inbox by inboxId
    public func inbox(for inboxId: String) throws -> Inbox? {
        try databaseReader.read { db in
            try DBInbox
                .fetchOne(db, id: inboxId)?
                .toDomain()
        }
    }

    /// Fetch inbox by clientId
    public func inbox(byClientId clientId: String) throws -> Inbox? {
        try databaseReader.read { db in
            try DBInbox
                .filter(DBInbox.Columns.clientId == clientId)
                .fetchOne(db)?
                .toDomain()
        }
    }

    public func vaultInbox() throws -> Inbox? {
        try databaseReader.read { db in
            try DBInbox
                .filter(DBInbox.Columns.isVault == true)
                .fetchOne(db)?
                .toDomain()
        }
    }

    public func nonVaultInboxes() throws -> [Inbox] {
        try databaseReader.read { db in
            try DBInbox
                .filter(DBInbox.Columns.isVault == false)
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    public func nonVaultUsedInboxes() throws -> [Inbox] {
        try databaseReader.read { db in
            let sql = """
                SELECT i.*
                FROM inbox i
                WHERE i.isVault = 0
                    AND EXISTS (
                        SELECT 1
                        FROM conversation c
                        WHERE c.inboxId = i.inboxId
                            AND c.isUnused = 0
                    )
                """
            return try DBInbox.fetchAll(db, sql: sql).map { $0.toDomain() }
        }
    }
}
