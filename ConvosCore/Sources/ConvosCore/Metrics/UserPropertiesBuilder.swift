import Combine
import ConvosMetrics
import Foundation
import GRDB

public final class UserPropertiesBuilder: @unchecked Sendable {
    private let databaseReader: any DatabaseReader
    private let currentInboxId: String

    public init(databaseReader: any DatabaseReader, currentInboxId: String) {
        self.databaseReader = databaseReader
        self.currentInboxId = currentInboxId
    }

    public func fetch() throws -> UserProperties {
        try databaseReader.read { [currentInboxId] db in
            try db.composeUserProperties(currentInboxId: currentInboxId)
        }
    }

    public func publisher(
        debounceFor interval: DispatchQueue.SchedulerTimeType.Stride = .seconds(30)
    ) -> AnyPublisher<UserProperties, Never> {
        let inboxId = currentInboxId
        return ValueObservation
            .tracking { db in
                try db.composeUserProperties(currentInboxId: inboxId)
            }
            .publisher(in: databaseReader)
            .debounce(for: interval, scheduler: DispatchQueue.global(qos: .utility))
            .catch { _ in Empty<UserProperties, Never>() }
            .eraseToAnyPublisher()
    }
}

fileprivate extension Database {
    func composeUserProperties(currentInboxId: String) throws -> UserProperties {
        let now: Date = Date()
        let cutoff24h: Date = now.addingTimeInterval(-24 * 60 * 60)
        let cutoff7d: Date = now.addingTimeInterval(-7 * 24 * 60 * 60)

        let contactCount: Int = try DBContact.fetchCount(self)

        let conversationCount: Int = try DBConversation
            .filter(!DBConversation.Columns.id.like("draft-%"))
            .fetchCount(self)

        let agentConversationIds: [String] = try String.fetchAll(
            self,
            sql: """
            SELECT DISTINCT mp.conversationId
            FROM memberProfile mp
            JOIN conversation c ON c.id = mp.conversationId
            WHERE mp.memberKind IS NOT NULL
            AND c.id NOT LIKE 'draft-%'
            """
        )

        let assistantConversationCount: Int = agentConversationIds.count

        let hasMessagedAssistant: Bool
        let lastAssistantMessageTimestamp: String?
        if agentConversationIds.isEmpty {
            hasMessagedAssistant = false
            lastAssistantMessageTimestamp = nil
        } else {
            let lastDate: Date? = try DBMessage
                .filter(agentConversationIds.contains(DBMessage.Columns.conversationId))
                .filter(DBMessage.Columns.senderId == currentInboxId)
                .select(max(DBMessage.Columns.date))
                .asRequest(of: Date.self)
                .fetchOne(self)
            hasMessagedAssistant = lastDate != nil
            lastAssistantMessageTimestamp = lastDate?.iso8601
        }

        let conversationCount24Hours: Int = try Int.fetchOne(
            self,
            sql: """
            SELECT COUNT(DISTINCT m.conversationId)
            FROM message m
            JOIN conversation c ON c.id = m.conversationId
            WHERE m.date > ?
            AND c.id NOT LIKE 'draft-%'
            """,
            arguments: [cutoff24h]
        ) ?? 0

        let conversationCount7Days: Int = try Int.fetchOne(
            self,
            sql: """
            SELECT COUNT(DISTINCT m.conversationId)
            FROM message m
            JOIN conversation c ON c.id = m.conversationId
            WHERE m.date > ?
            AND c.id NOT LIKE 'draft-%'
            """,
            arguments: [cutoff7d]
        ) ?? 0

        let oldestActiveCreatedAt: Date? = try DBConversation
            .filter(!DBConversation.Columns.id.like("draft-%"))
            .filter(DBConversation.Columns.expiresAt == nil
                || DBConversation.Columns.expiresAt > now)
            .filter(DBConversation.Columns.isUnused == false)
            .select(min(DBConversation.Columns.createdAt))
            .asRequest(of: Date.self)
            .fetchOne(self)
        let maxActiveConvoAge: Float = oldestActiveCreatedAt
            .map { Float(now.timeIntervalSince($0)) } ?? 0

        return UserProperties(
            hasMessagedAssistant: hasMessagedAssistant,
            lastAssistantMessageTimestamp: lastAssistantMessageTimestamp,
            contactCount: contactCount,
            conversationCount: conversationCount,
            assistantConversationCount: assistantConversationCount,
            conversationCount24Hours: conversationCount24Hours,
            conversationCount7Days: conversationCount7Days,
            maxActiveConvoAge: maxActiveConvoAge
        )
    }
}

private extension Date {
    var iso8601: String {
        formatted(.iso8601)
    }
}
