import Foundation
import GRDB
@preconcurrency import XMTPiOS

public actor VaultImportSyncDrainer {
    private let lifecycleManager: any InboxLifecycleManagerProtocol
    private let databaseReader: any DatabaseReader
    private let environment: AppEnvironment
    private let xmtpStaticOperations: SendableXMTPOperations

    private var drainTask: Task<Void, Never>?
    private var pendingInboxIds: Set<String> = []
    private var syncedInboxIds: Set<String> = []
    private var sortedQueue: [(inboxId: String, clientId: String)] = []

    private static let settleDelay: TimeInterval = 8
    private static let betweenInboxDelay: TimeInterval = 1
    private static let perInboxTimeout: TimeInterval = 30

    public var remainingCount: Int { pendingInboxIds.subtracting(syncedInboxIds).count }
    public var isDraining: Bool { drainTask?.isCancelled == false }

    public init(
        lifecycleManager: any InboxLifecycleManagerProtocol,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment,
        xmtpStaticOperations: any XMTPStaticOperations.Type = Client.self
    ) {
        self.lifecycleManager = lifecycleManager
        self.databaseReader = databaseReader
        self.environment = environment
        self.xmtpStaticOperations = SendableXMTPOperations(xmtpStaticOperations)
    }

    public func startDraining(importedInboxIds: Set<String>) {
        let newIds = importedInboxIds.subtracting(syncedInboxIds)
        guard !newIds.isEmpty else { return }

        pendingInboxIds.formUnion(newIds)

        if drainTask == nil || drainTask?.isCancelled == true {
            sortedQueue = []
            resumeDraining()
        }
    }

    public func resume() {
        guard !pendingInboxIds.subtracting(syncedInboxIds).isEmpty else { return }
        resumeDraining()
    }

    public func pause() {
        drainTask?.cancel()
        drainTask = nil
    }

    public func stop() {
        drainTask?.cancel()
        drainTask = nil
        pendingInboxIds.removeAll()
        syncedInboxIds.removeAll()
        sortedQueue = []
    }

    private func resumeDraining() {
        guard drainTask == nil || drainTask?.isCancelled == true else { return }
        drainTask = Task { [weak self] in
            guard let self else { return }
            await self.drain()
        }
    }

    private func drain() async {
        while true {
            let remaining = pendingInboxIds.subtracting(syncedInboxIds)
            guard !remaining.isEmpty else { break }

            sortedQueue = await fetchAndSortByActivity(inboxIds: remaining)

            if sortedQueue.isEmpty {
                Log.warning("VaultImportSyncDrainer: no inboxes found in database for \(remaining.count) pending ID(s), skipping")
                syncedInboxIds.formUnion(remaining)
                break
            }

            let total = pendingInboxIds.count
            Log.info("VaultImportSyncDrainer: draining \(sortedQueue.count) inboxes (\(syncedInboxIds.count)/\(total) already synced)")

            while let inbox = sortedQueue.first {
                guard !Task.isCancelled else { return }
                sortedQueue.removeFirst()

                if syncedInboxIds.contains(inbox.inboxId) { continue }

                if await lifecycleManager.isAwake(clientId: inbox.clientId) {
                    syncedInboxIds.insert(inbox.inboxId)
                    continue
                }

                do {
                    Log.debug("VaultImportSyncDrainer: syncing inbox \(inbox.inboxId)")
                    try await withTimeout(seconds: Self.perInboxTimeout) {
                        let service = try await self.lifecycleManager.wake(
                            clientId: inbox.clientId,
                            inboxId: inbox.inboxId,
                            reason: .activityRanking
                        )
                        _ = try await service.inboxStateManager.waitForInboxReadyResult()
                    }

                    try? await Task.sleep(for: .seconds(Self.settleDelay))
                    guard !Task.isCancelled else { return }

                    await lifecycleManager.sleep(clientId: inbox.clientId)
                    syncedInboxIds.insert(inbox.inboxId)
                    Log.debug("VaultImportSyncDrainer: finished inbox \(inbox.inboxId)")

                    let synced = syncedInboxIds.count
                    if synced.isMultiple(of: 10) {
                        Log.info("VaultImportSyncDrainer: progress \(synced)/\(total)")
                    }

                    try? await Task.sleep(for: .seconds(Self.betweenInboxDelay))
                } catch {
                    Log.warning("VaultImportSyncDrainer: failed to sync inbox \(inbox.inboxId): \(error)")
                    await lifecycleManager.sleep(clientId: inbox.clientId)
                    syncedInboxIds.insert(inbox.inboxId)
                }
            }

            guard !Task.isCancelled else { return }
        }

        Log.info("VaultImportSyncDrainer: completed \(syncedInboxIds.count)/\(pendingInboxIds.count)")
        pendingInboxIds.removeAll()
        syncedInboxIds.removeAll()
        sortedQueue = []
        drainTask = nil
    }

    private struct InboxRow {
        let inboxId: String
        let clientId: String
        let conversationId: String?
    }

    private func fetchAndSortByActivity(inboxIds: Set<String>) async -> [(inboxId: String, clientId: String)] {
        let inboxRows: [InboxRow]
        do {
            inboxRows = try await databaseReader.read { db in
                let placeholders = inboxIds.map { _ in "?" }.joined(separator: ",")
                let sql = """
                    SELECT i.inboxId, i.clientId, c.id as conversationId
                    FROM inbox i
                    LEFT JOIN conversation c ON c.clientId = i.clientId
                        AND c.id NOT LIKE 'draft-%'
                    WHERE i.inboxId IN (\(placeholders))
                    """
                return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(Array(inboxIds))).map { row in
                    InboxRow(
                        inboxId: row["inboxId"],
                        clientId: row["clientId"],
                        conversationId: row["conversationId"]
                    )
                }
            }
        } catch {
            Log.error("VaultImportSyncDrainer: failed to fetch inbox rows: \(error)")
            return []
        }

        let conversationIds = inboxRows.compactMap { $0.conversationId }

        var activityByConversation: [String: Int64] = [:]
        if !conversationIds.isEmpty {
            do {
                let api = XMTPAPIOptionsBuilder.build(environment: environment)
                let metadata = try await xmtpStaticOperations.getNewestMessageMetadata(
                    groupIds: conversationIds,
                    api: api
                )
                for (id, meta) in metadata {
                    activityByConversation[id] = meta.createdNs
                }
            } catch {
                Log.warning("VaultImportSyncDrainer: failed to fetch message metadata, using unsorted order: \(error)")
            }
        }

        var inboxActivity: [String: Int64] = [:]
        for row in inboxRows {
            guard let conversationId = row.conversationId,
                  let ns = activityByConversation[conversationId] else { continue }
            let existing = inboxActivity[row.inboxId] ?? 0
            if ns > existing {
                inboxActivity[row.inboxId] = ns
            }
        }

        let uniqueInboxes = Dictionary(grouping: inboxRows, by: { $0.inboxId })
            .compactMap { _, rows -> (inboxId: String, clientId: String)? in
                guard let first = rows.first else { return nil }
                return (inboxId: first.inboxId, clientId: first.clientId)
            }

        return uniqueInboxes.sorted { a, b in
            let aActivity = inboxActivity[a.inboxId] ?? 0
            let bActivity = inboxActivity[b.inboxId] ?? 0
            return aActivity > bActivity
        }
    }
}
