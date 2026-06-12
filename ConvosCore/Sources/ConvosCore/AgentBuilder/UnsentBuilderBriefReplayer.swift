import Foundation
import GRDB
import os

/// Session-wide recovery for builder briefs the app died holding.
///
/// The summary (prompt + `bundledMessageIds`) is persisted before the bundle
/// send, and the send can hold for up to 150s waiting for the agent to join
/// (`OutgoingMessageWriter.waitForAgentMember`). If the process dies in that
/// window, nothing re-sends the brief: the agent joins a conversation whose
/// instructions never arrived, while the persisted summary renders a card
/// implying they did.
///
/// A summary whose bundled rows are absent from the message table is that
/// exact signature -- the rows are created at prepare time, after the hold.
/// On session start this replayer scans for them and re-sends the prompt
/// text through the normal builder-bundle path (gated on agent membership
/// like any other builder send). The replay is self-extinguishing: the send
/// persists a row under the same client id the scan checks. Media staged in
/// memory at Make is not recoverable after process death and is skipped.
public final class UnsentBuilderBriefReplayer: Sendable {
    public struct PendingBrief: Sendable, Equatable {
        public let conversationId: String
        public let prompt: String
        public let textClientMessageId: String
    }

    /// Summaries older than this are history, not an interrupted send --
    /// among other things, message expiry can delete a delivered brief's
    /// rows long after the fact, and that must not resurrect it.
    static let replayWindow: TimeInterval = 30 * 60

    private let databaseReader: any DatabaseReader
    private let sendBrief: @Sendable (PendingBrief) async -> Void
    /// Only summaries persisted before this process started are candidates:
    /// a summary created in this process has its send in flight right here
    /// (the hold), and replaying it would double-send.
    private let processStart: Date
    private let replayTask: OSAllocatedUnfairLock<Task<Void, Never>?> = .init(initialState: nil)

    public init(
        databaseReader: any DatabaseReader,
        processStart: Date = Date(),
        sendBrief: @escaping @Sendable (PendingBrief) async -> Void
    ) {
        self.databaseReader = databaseReader
        self.processStart = processStart
        self.sendBrief = sendBrief
    }

    /// One-shot scan + replay. Safe to call repeatedly -- a running replay
    /// is cancelled and restarted.
    public func start() {
        let new: Task<Void, Never> = Task { [weak self] in
            await self?.replayPendingBriefs()
        }
        replayTask.withLock { existing in
            existing?.cancel()
            existing = new
        }
    }

    public func stop() {
        replayTask.withLock { existing in
            existing?.cancel()
            existing = nil
        }
    }

    private func replayPendingBriefs() async {
        let reader = databaseReader
        let start = processStart
        let briefs: [PendingBrief]
        do {
            briefs = try await reader.read { db in
                try Self.pendingBriefs(db: db, processStart: start, now: Date())
            }
        } catch {
            Log.error("UnsentBuilderBriefReplayer: scan failed: \(error.localizedDescription)")
            return
        }
        for brief in briefs {
            if Task.isCancelled { return }
            Log.info("UnsentBuilderBriefReplayer: replaying brief for \(brief.conversationId)")
            QAEvent.emit(.message, "builder_brief_replayed", ["conversationId": brief.conversationId])
            await sendBrief(brief)
        }
    }

    /// A pending brief is a summary persisted before this process started,
    /// recent enough to be an interrupted send, with a non-empty prompt and
    /// none of its bundled client ids present in the message table (by id or
    /// clientMessageId -- the sender's row keeps the client id in both until
    /// prepare swaps the id column).
    static func pendingBriefs(db: Database, processStart: Date, now: Date) throws -> [PendingBrief] {
        let summaryRows: [DBAgentBuilderSummary] = try DBAgentBuilderSummary.fetchAll(db)
        var briefs: [PendingBrief] = []
        for row in summaryRows {
            guard let summary = try? row.toAgentBuilderSummary() else { continue }
            guard !summary.prompt.isEmpty, !summary.bundledMessageIds.isEmpty else { continue }
            guard summary.createdAt < processStart else { continue }
            guard now.timeIntervalSince(summary.createdAt) < Self.replayWindow else { continue }
            let ids: [String] = Array(summary.bundledMessageIds)
            let rowCount: Int = try DBMessage
                .filter(ids.contains(DBMessage.Columns.id) || ids.contains(DBMessage.Columns.clientMessageId))
                .fetchCount(db)
            guard rowCount == 0 else { continue }
            briefs.append(PendingBrief(
                conversationId: row.conversationId,
                prompt: summary.prompt,
                textClientMessageId: summary.bundledMessageIds.min() ?? UUID().uuidString
            ))
        }
        return briefs
    }
}
