import Foundation
import GRDB

/// Runs periodically to maintain the quarantine table:
///
/// - Promotes a quarantined conversation to the main feed when its sender
///   has since become a contact (and is not blocked) by setting
///   `quarantineReleasedAt = now`.
/// - Deletes a quarantined conversation whose hold window has expired
///   (default 7 days, configurable via `Constant.ttl`). Deletion cascades
///   to messages and member rows via existing foreign-key onDelete rules.
///
/// The sweeper is idempotent and safe to call repeatedly. A scheduled
/// caller (`SessionManager.observe()`) runs `sweep()` on launch and once
/// per hour while the app is foregrounded.
public protocol QuarantineSweeperProtocol: Sendable {
    func sweep() async throws
}

final class QuarantineSweeper: QuarantineSweeperProtocol, @unchecked Sendable {
    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader
    private let contactsRepository: any ContactsRepositoryProtocol
    private let now: @Sendable () -> Date

    init(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        contactsRepository: any ContactsRepositoryProtocol,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.contactsRepository = contactsRepository
        self.now = now
    }

    func sweep() async throws {
        let snapshots = try await fetchActiveQuarantinedSnapshots()
        guard !snapshots.isEmpty else {
            Log.debug("QuarantineSweeper: no quarantined conversations to sweep")
            return
        }

        let currentTime = now()
        var promotionIds: [String] = []
        var deletionIds: [String] = []

        for snapshot in snapshots {
            let isContact = (try? contactsRepository.isContact(inboxId: snapshot.creatorId)) ?? false
            let isBlocked = (try? contactsRepository.isBlocked(inboxId: snapshot.creatorId)) ?? false

            if isContact && !isBlocked {
                promotionIds.append(snapshot.conversationId)
            } else if currentTime.timeIntervalSince(snapshot.quarantinedAt) > Constant.ttl {
                deletionIds.append(snapshot.conversationId)
            }
        }

        guard !promotionIds.isEmpty || !deletionIds.isEmpty else { return }

        // Sendable capture: GRDB's `write { ... }` closure is `@Sendable`, so
        // it can only capture immutable bindings. Bind `let` copies of the
        // accumulators before the transaction runs.
        let promotionsToApply: [String] = promotionIds
        let deletionsToApply: [String] = deletionIds
        let appliedAt: Date = currentTime

        try await databaseWriter.write { db in
            for id in promotionsToApply {
                guard let existing = try DBConversation.fetchOne(db, key: id) else { continue }
                let updated = existing.with(
                    quarantinedAt: existing.quarantinedAt,
                    quarantineReleasedAt: appliedAt
                )
                try updated.save(db)
            }
            for id in deletionsToApply {
                _ = try DBConversation
                    .filter(DBConversation.Columns.id == id)
                    .deleteAll(db)
            }
        }

        if !promotionsToApply.isEmpty {
            Log.info("QuarantineSweeper: promoted \(promotionsToApply.count) conversations to main feed")
        }
        if !deletionsToApply.isEmpty {
            Log.info("QuarantineSweeper: deleted \(deletionsToApply.count) expired quarantined conversations")
        }
    }

    // MARK: - Internals

    private struct QuarantinedConversationSnapshot: Sendable {
        let conversationId: String
        let creatorId: String
        let quarantinedAt: Date
    }

    private func fetchActiveQuarantinedSnapshots() async throws -> [QuarantinedConversationSnapshot] {
        try await databaseReader.read { db in
            let rows = try DBConversation
                .filter(DBConversation.Columns.quarantinedAt != nil)
                .filter(DBConversation.Columns.quarantineReleasedAt == nil)
                .fetchAll(db)
            return rows.compactMap { row -> QuarantinedConversationSnapshot? in
                guard let quarantinedAt = row.quarantinedAt else { return nil }
                return QuarantinedConversationSnapshot(
                    conversationId: row.id,
                    creatorId: row.creatorId,
                    quarantinedAt: quarantinedAt
                )
            }
        }
    }

    enum Constant {
        /// Default 7-day TTL for quarantined conversations. Stranger
        /// conversations are deleted after this window if their sender has
        /// not become a contact in the meantime.
        static let ttl: TimeInterval = 7 * 24 * 60 * 60
        /// Hourly cadence for foreground-only periodic sweeps.
        static let foregroundSweepInterval: TimeInterval = 60 * 60
    }
}

// MARK: - Mock

public final class MockQuarantineSweeper: QuarantineSweeperProtocol, @unchecked Sendable {
    public init() {}
    public func sweep() async throws {}
}
