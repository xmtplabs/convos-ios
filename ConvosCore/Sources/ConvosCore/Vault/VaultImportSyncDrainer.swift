import Foundation
import GRDB
@preconcurrency import XMTPiOS

struct PendingInboxEntry: Sendable {
    let inboxId: String
    let clientId: String
    let attempts: Int
}

public actor VaultImportSyncDrainer {
    private let lifecycleManager: any InboxLifecycleManagerProtocol
    private let databaseReader: any DatabaseReader
    private let databaseWriter: (any DatabaseWriter)?
    private let environment: AppEnvironment
    private let xmtpStaticOperations: SendableXMTPOperations

    private var drainTask: Task<Void, Never>?
    private var hasPendingHighPriority: Bool = false

    private static let maxConcurrent: Int = 3
    private static let perInboxTimeout: TimeInterval = 30
    private static let maxAttempts: Int = 3
    private static let retryDelays: [TimeInterval] = [5, 15]

    public var remainingCount: Int {
        get async {
            (try? await databaseReader.read { db in
                try DBInbox
                    .filter(DBInbox.Columns.vaultSyncState == VaultSyncState.pending)
                    .fetchCount(db)
            }) ?? 0
        }
    }

    public var isDraining: Bool { drainTask != nil && drainTask?.isCancelled == false }

    public init(
        lifecycleManager: any InboxLifecycleManagerProtocol,
        databaseReader: any DatabaseReader,
        databaseWriter: (any DatabaseWriter)? = nil,
        environment: AppEnvironment,
        xmtpStaticOperations: any XMTPStaticOperations.Type = Client.self
    ) {
        self.lifecycleManager = lifecycleManager
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter
        self.environment = environment
        self.xmtpStaticOperations = SendableXMTPOperations(xmtpStaticOperations)
    }

    public func startDraining(importedInboxIds: Set<String>) async {
        guard let databaseWriter else { return }
        let newIds = importedInboxIds
        guard !newIds.isEmpty else { return }

        do {
            try await databaseWriter.write { db in
                for inboxId in newIds {
                    try db.execute(
                        sql: """
                            UPDATE inbox SET vaultSyncState = ?, vaultSyncAttempts = 0
                            WHERE inboxId = ? AND vaultSyncState IN (?, ?)
                            """,
                        arguments: [
                            VaultSyncState.pending.rawValue,
                            inboxId,
                            VaultSyncState.none.rawValue,
                            VaultSyncState.failed.rawValue,
                        ]
                    )
                }
            }
        } catch {
            Log.error("VaultImportSyncDrainer: failed to mark inboxes as pending: \(error)")
        }

        hasPendingHighPriority = true
        ensureDraining()
    }

    public func resumeFromDatabase() async {
        let hasPending: Bool = (try? await databaseReader.read { db in
            try DBInbox
                .filter([VaultSyncState.pending, .failed].map(\.rawValue).contains(DBInbox.Columns.vaultSyncState))
                .filter(DBInbox.Columns.vaultSyncAttempts < Self.maxAttempts)
                .fetchCount(db) > 0
        }) ?? false

        guard hasPending else { return }
        Log.info("VaultImportSyncDrainer: found pending inboxes in database, resuming")
        ensureDraining()
    }

    public func resume() async {
        await resumeFromDatabase()
    }

    public func pause() {
        drainTask?.cancel()
        drainTask = nil
    }

    public func stop() {
        drainTask?.cancel()
        drainTask = nil
        hasPendingHighPriority = false
    }

    private func ensureDraining() {
        guard drainTask == nil || drainTask?.isCancelled == true else { return }
        drainTask = Task { [weak self] in
            guard let self else { return }
            await self.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled {
            let batch = await fetchPendingBatch()
            guard !batch.isEmpty else { break }

            let total = batch.count
            Log.info("VaultImportSyncDrainer: processing \(total) inbox(es) concurrently (max \(Self.maxConcurrent))")

            hasPendingHighPriority = false

            await withTaskGroup(of: Void.self) { group in
                var inflight: Int = 0
                for inbox in batch {
                    guard !Task.isCancelled else { break }
                    if hasPendingHighPriority {
                        Log.info("VaultImportSyncDrainer: new inbox(es) arrived, will re-evaluate after current batch")
                        break
                    }

                    if inflight >= Self.maxConcurrent {
                        await group.next()
                        inflight -= 1
                    }

                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.syncOneInbox(inbox)
                    }
                    inflight += 1
                }
            }

            guard !Task.isCancelled else { return }
        }

        Log.info("VaultImportSyncDrainer: drain complete")
        drainTask = nil
    }

    private func syncOneInbox(_ inbox: PendingInboxEntry) async {
        let inboxId = inbox.inboxId
        let clientId = inbox.clientId

        if await lifecycleManager.isAwake(clientId: clientId) {
            await markSynced(inboxId: inboxId)
            return
        }

        do {
            try await withTimeout(seconds: Self.perInboxTimeout) {
                let service = try await self.lifecycleManager.wake(
                    clientId: clientId,
                    inboxId: inboxId,
                    reason: .activityRanking
                )
                _ = try await service.inboxStateManager.waitForInboxReadyResult()
            }

            await lifecycleManager.sleep(clientId: clientId)
            await markSynced(inboxId: inboxId)
            Log.debug("VaultImportSyncDrainer: synced inbox \(inboxId)")
        } catch {
            await lifecycleManager.sleep(clientId: clientId)
            let nextAttempt = inbox.attempts + 1
            if nextAttempt >= Self.maxAttempts {
                Log.warning("VaultImportSyncDrainer: giving up on inbox \(inboxId) after \(nextAttempt) attempts: \(error)")
                await markFailed(inboxId: inboxId, attempts: nextAttempt)
            } else {
                Log.warning("VaultImportSyncDrainer: inbox \(inboxId) attempt \(nextAttempt)/\(Self.maxAttempts) failed: \(error)")
                await markFailed(inboxId: inboxId, attempts: nextAttempt)
            }
        }
    }

    private func markSynced(inboxId: String) async {
        guard let databaseWriter else { return }
        try? await databaseWriter.write { db in
            try db.execute(
                sql: "UPDATE inbox SET vaultSyncState = ? WHERE inboxId = ?",
                arguments: [VaultSyncState.synced.rawValue, inboxId]
            )
        }
    }

    private func markFailed(inboxId: String, attempts: Int) async {
        guard let databaseWriter else { return }
        try? await databaseWriter.write { db in
            try db.execute(
                sql: "UPDATE inbox SET vaultSyncState = ?, vaultSyncAttempts = ? WHERE inboxId = ?",
                arguments: [VaultSyncState.failed.rawValue, attempts, inboxId]
            )
        }
    }

    private func fetchPendingBatch() async -> [PendingInboxEntry] {
        let pendingRows: [PendingInboxEntry]
        do {
            pendingRows = try await databaseReader.read { db in
                let sql = """
                    SELECT i.inboxId, i.clientId, i.vaultSyncAttempts, c.id as conversationId
                    FROM inbox i
                    LEFT JOIN conversation c ON c.clientId = i.clientId
                        AND c.id NOT LIKE 'draft-%'
                    WHERE i.vaultSyncState IN (?, ?)
                        AND i.vaultSyncAttempts < ?
                    """
                let rows = try Row.fetchAll(db, sql: sql, arguments: [
                    VaultSyncState.pending.rawValue,
                    VaultSyncState.failed.rawValue,
                    Self.maxAttempts,
                ])
                return rows.map { row in
                    PendingInboxEntry(
                        inboxId: row["inboxId"],
                        clientId: row["clientId"],
                        attempts: row["vaultSyncAttempts"]
                    )
                }
            }
        } catch {
            Log.error("VaultImportSyncDrainer: failed to fetch pending inboxes: \(error)")
            return []
        }

        let uniqueInboxes = Dictionary(grouping: pendingRows, by: { $0.inboxId })
            .compactMap { _, rows in rows.first }

        guard !uniqueInboxes.isEmpty else { return [] }

        return await sortByActivity(inboxes: uniqueInboxes)
    }

    private func sortByActivity(
        inboxes: [PendingInboxEntry]
    ) async -> [PendingInboxEntry] {
        let conversationIds: [String: String]
        do {
            let inboxIds = inboxes.map { $0.clientId }
            conversationIds = try await databaseReader.read { db in
                let placeholders = inboxIds.map { _ in "?" }.joined(separator: ",")
                let sql = """
                    SELECT clientId, id as conversationId FROM conversation
                    WHERE clientId IN (\(placeholders)) AND id NOT LIKE 'draft-%'
                    """
                var mapping: [String: String] = [:]
                for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(inboxIds)) {
                    let clientId: String = row["clientId"]
                    let convId: String = row["conversationId"]
                    mapping[clientId] = convId
                }
                return mapping
            }
        } catch {
            return inboxes
        }

        let allConvIds = Array(conversationIds.values)
        guard !allConvIds.isEmpty else { return inboxes }

        var activityByConversation: [String: Int64] = [:]
        do {
            let api = XMTPAPIOptionsBuilder.build(environment: environment)
            let metadata = try await xmtpStaticOperations.getNewestMessageMetadata(
                groupIds: allConvIds,
                api: api
            )
            for (id, meta) in metadata {
                activityByConversation[id] = meta.createdNs
            }
        } catch {
            Log.warning("VaultImportSyncDrainer: failed to fetch activity metadata, using unsorted order: \(error)")
            return inboxes
        }

        return inboxes.sorted { a, b in
            let aConv = conversationIds[a.clientId]
            let bConv = conversationIds[b.clientId]
            let aActivity = aConv.flatMap { activityByConversation[$0] } ?? 0
            let bActivity = bConv.flatMap { activityByConversation[$0] } ?? 0
            return aActivity > bActivity
        }
    }
}
