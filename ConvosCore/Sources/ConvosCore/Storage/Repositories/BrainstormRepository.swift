import Combine
import Foundation
import GRDB

/// One brainstorm message: a standard reply whose reference is a thinking
/// moment or a brainstorm anchor. `agentInboxId` is the agent whose
/// brainstorm tab the message belongs to, resolved from the referenced row.
public struct BrainstormMessageRecord: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let clientMessageId: String
    public let agentInboxId: String
    public let senderInboxId: String
    public let text: String
    public let sentAtNs: Int64
    public let status: MessageStatus
    public let referenceId: String

    public var sentAt: Date {
        Date(timeIntervalSince1970: TimeInterval(sentAtNs) / 1_000_000_000)
    }
}

public struct BrainstormAnchorRecord: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let agentInboxId: String
    public let sentAtNs: Int64
}

public struct BrainstormFeed: Equatable, Sendable {
    public let anchors: [BrainstormAnchorRecord]
    public let messages: [BrainstormMessageRecord]

    public static let empty: BrainstormFeed = BrainstormFeed(anchors: [], messages: [])

    public init(anchors: [BrainstormAnchorRecord], messages: [BrainstormMessageRecord]) {
        self.anchors = anchors
        self.messages = messages
    }
}

public protocol BrainstormRepositoryProtocol: Sendable {
    /// Live feed of every brainstorm anchor and brainstorm message in the
    /// conversation, both in ascending sent order. Consumers filter by
    /// `agentInboxId` for a specific agent's tab.
    func feedPublisher(for conversationId: String) -> AnyPublisher<BrainstormFeed, Never>
}

public final class BrainstormRepository: BrainstormRepositoryProtocol, Sendable {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func feedPublisher(for conversationId: String) -> AnyPublisher<BrainstormFeed, Never> {
        ValueObservation
            .tracking { db in
                try Self.feed(db: db, conversationId: conversationId)
            }
            .publisher(in: databaseReader)
            .replaceError(with: .empty)
            .eraseToAnyPublisher()
    }

    private static func feed(db: Database, conversationId: String) throws -> BrainstormFeed {
        let anchors = try DBBrainstormAnchor
            .filter(DBBrainstormAnchor.Columns.conversationId == conversationId)
            .order(DBBrainstormAnchor.Columns.sentAtNs.asc)
            .fetchAll(db)
        let moments = try DBThinkingMoment
            .filter(DBThinkingMoment.Columns.conversationId == conversationId)
            .fetchAll(db)

        var agentByReferenceId: [String: String] = [:]
        for moment in moments {
            agentByReferenceId[moment.id] = moment.senderInboxId
        }
        for anchor in anchors {
            agentByReferenceId[anchor.id] = anchor.agentInboxId
        }

        let anchorRecords: [BrainstormAnchorRecord] = anchors.map { anchor in
            BrainstormAnchorRecord(id: anchor.id, agentInboxId: anchor.agentInboxId, sentAtNs: anchor.sentAtNs)
        }

        guard !agentByReferenceId.isEmpty else {
            return BrainstormFeed(anchors: anchorRecords, messages: [])
        }

        let referenceIds = Array(agentByReferenceId.keys)
        let rows = try DBMessage
            .filter(DBMessage.Columns.conversationId == conversationId)
            .filter(DBMessage.Columns.messageType == DBMessageType.reply.rawValue)
            .filter(referenceIds.contains(DBMessage.Columns.sourceMessageId))
            .order(DBMessage.Columns.dateNs.asc)
            .fetchAll(db)

        let messages: [BrainstormMessageRecord] = rows.compactMap { (row: DBMessage) -> BrainstormMessageRecord? in
            guard let referenceId = row.sourceMessageId,
                  let agentInboxId = agentByReferenceId[referenceId] else { return nil }
            let body: String? = row.text ?? row.emoji
            guard let body, !body.isEmpty else { return nil }
            return BrainstormMessageRecord(
                id: row.id,
                clientMessageId: row.clientMessageId,
                agentInboxId: agentInboxId,
                senderInboxId: row.senderId,
                text: body,
                sentAtNs: row.dateNs,
                status: row.status,
                referenceId: referenceId
            )
        }

        return BrainstormFeed(anchors: anchorRecords, messages: messages)
    }
}
