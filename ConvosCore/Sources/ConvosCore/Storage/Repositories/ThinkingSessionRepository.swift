import Combine
import Foundation
import GRDB

public enum ThinkingMomentState: String, Equatable, Hashable, Sendable, Codable {
    case start, stop
}

/// One agent thinking event (a single `start` or `stop`). The detail view's
/// timeline iterates moments; the inline footer reads the latest moment's
/// content. Persisted independently so the full history survives app
/// launches.
public struct ThinkingMoment: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let content: String
    public let state: ThinkingMomentState
    public let sentAtNs: Int64
    public let resultMessageId: String?

    public var sentAt: Date {
        Date(timeIntervalSince1970: TimeInterval(sentAtNs) / 1_000_000_000)
    }
}

/// Aggregated session view of a chain of thinking moments sharing the same
/// `(conversationId, senderInboxId, targetMessageId)` triple. Built at read
/// time by the repository from the moment rows.
public struct ThinkingSessionRecord: Equatable, Sendable, Identifiable {
    public let id: String
    public let conversationId: String
    public let senderInboxId: String
    public let targetMessageId: String
    /// Moments in chronological (ascending) order.
    public let moments: [ThinkingMoment]

    public var latestMoment: ThinkingMoment? { moments.last }
    public var content: String { latestMoment?.content ?? "" }
    public var startedAtNs: Int64 { moments.first?.sentAtNs ?? 0 }
    /// First (earliest) `stop.resultMessageId` along the session, or nil if
    /// the session was never resolved with a reply.
    public var resultMessageId: String? {
        moments.first(where: { $0.state == .stop && $0.resultMessageId != nil })?.resultMessageId
    }
    /// True until a `stop` arrives. The session is closed once any `stop`
    /// moment has been recorded, whether or not it carried a result.
    public var isActive: Bool {
        latestMoment?.state == .start
    }
}

public protocol ThinkingSessionRepositoryProtocol: Sendable {
    /// Every session ever recorded for the conversation, ordered by start
    /// time ascending. Consumers decide what to render: the messages list
    /// only anchors footers on sessions worth surfacing (active or
    /// resolved-with-result), while the detail sheet shows the full
    /// timeline regardless of how the session ended so reopened history
    /// stays intact even after a `stop` without `resultMessageId`.
    func activeSessions(for conversationId: String) async throws -> [ThinkingSessionRecord]
    func activeSessionsPublisher(for conversationId: String) -> AnyPublisher<[ThinkingSessionRecord], Never>
}

public final class ThinkingSessionRepository: ThinkingSessionRepositoryProtocol, Sendable {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func activeSessions(for conversationId: String) async throws -> [ThinkingSessionRecord] {
        try await databaseReader.read { db in
            try Self.aggregatedSessions(db: db, conversationId: conversationId)
        }
    }

    public func activeSessionsPublisher(for conversationId: String) -> AnyPublisher<[ThinkingSessionRecord], Never> {
        ValueObservation
            .tracking { db in
                try Self.aggregatedSessions(db: db, conversationId: conversationId)
            }
            .publisher(in: databaseReader)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    private static func aggregatedSessions(db: Database, conversationId: String) throws -> [ThinkingSessionRecord] {
        let rows = try DBThinkingMoment
            .filter(DBThinkingMoment.Columns.conversationId == conversationId)
            .order(DBThinkingMoment.Columns.sentAtNs.asc)
            .fetchAll(db)

        // Group by (senderInboxId, targetMessageId), preserving chronological
        // moment order within each group. A dictionary loses iteration order
        // so we accumulate keys in a separate array to keep the outer
        // session list ordered by each session's first moment.
        var orderedKeys: [String] = []
        var grouped: [String: [DBThinkingMoment]] = [:]
        for row in rows {
            let key = "\(row.senderInboxId):\(row.targetMessageId)"
            if grouped[key] == nil {
                orderedKeys.append(key)
            }
            grouped[key, default: []].append(row)
        }

        return orderedKeys.compactMap { key in
            guard let group = grouped[key], let first = group.first else { return nil }
            let moments: [ThinkingMoment] = group.map { row in
                ThinkingMoment(
                    id: row.id,
                    content: row.content,
                    state: ThinkingMomentState(rawValue: row.state) ?? .start,
                    sentAtNs: row.sentAtNs,
                    resultMessageId: row.resultMessageId
                )
            }
            return ThinkingSessionRecord(
                id: key,
                conversationId: conversationId,
                senderInboxId: first.senderInboxId,
                targetMessageId: first.targetMessageId,
                moments: moments
            )
        }
    }
}
