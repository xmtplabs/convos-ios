import Foundation
import GRDB

/// Runs periodically to maintain the quarantine table:
///
/// - Promotes a quarantined conversation to the main feed when its sender
///   has since become a contact (and is not blocked) by setting
///   `quarantineReleasedAt = now` AND bumping `consent` to `.allowed`
///   (mirrors the side-effect parity that `StreamProcessor.decideInboundConversation`
///   applies on the `.deliver` path: the main feed query is scoped to
///   `consent IN (.allowed)`, so promotion has to flip the column or the
///   row stays hidden). Before applying the DB write, the sweeper also
///   asks the injected `consentBumper` closure to bump XMTP-side consent
///   for the conversation; if that throws (client not ready, conversation
///   missing from local XMTP cache, network error), the per-row promotion
///   is skipped and retried on the next sweep so we never end up with a
///   row that's visible in the feed but whose XMTP consent is still
///   `.unknown` (which would cause `StreamProcessor.shouldProcessConversation`
///   to silently drop future inbound messages).
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
    private let consentBumper: @Sendable (String) async throws -> Void
    private let now: @Sendable () -> Date

    /// - Parameter consentBumper: Bumps XMTP-side consent to `.allowed` for
    ///   the given conversationId. Production wiring in
    ///   `SessionManager.scheduleQuarantineSweeper` routes through the
    ///   messaging service's `XMTPClientProvider.update(consent:for:)`.
    ///   Throw to skip this row's promotion on the current sweep; the row
    ///   stays quarantined and the next sweep retries.
    init(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        contactsRepository: any ContactsRepositoryProtocol,
        consentBumper: @escaping @Sendable (String) async throws -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.contactsRepository = contactsRepository
        self.consentBumper = consentBumper
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
                // Bump XMTP consent before committing the DB promotion so a
                // failure here defers the promotion to the next sweep cycle
                // rather than leaving the row visible in the feed with
                // `.unknown` XMTP consent (which silently gates future
                // inbound messages in `shouldProcessConversation`).
                do {
                    try await consentBumper(snapshot.conversationId)
                    promotionIds.append(snapshot.conversationId)
                } catch {
                    Log.warning(
                        "QuarantineSweeper: XMTP consent bump failed for \(snapshot.conversationId), deferring promotion: \(error.localizedDescription)"
                    )
                }
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
                let updated = existing
                    .with(
                        quarantinedAt: existing.quarantinedAt,
                        quarantineReleasedAt: appliedAt
                    )
                    .with(consent: .allowed)
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
