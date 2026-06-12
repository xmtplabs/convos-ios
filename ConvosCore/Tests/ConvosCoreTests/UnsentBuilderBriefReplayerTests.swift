@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for the unsent-brief scan: a summary persisted before this
/// process started, recent, with a prompt and none of its bundled rows in
/// the message table, identifies a builder brief the previous process died
/// holding (the agent-join hold lasts up to 150s). The scan must not match
/// briefs whose rows landed, briefs created in this process (their send is
/// in flight here), or old summaries whose rows expired.
@Suite("Unsent builder brief replayer Tests", .serialized)
struct UnsentBuilderBriefReplayerTests {
    private static let conversationId: String = "convo-brief"

    private static func seedConversation(db: Database) throws {
        try DBMember(inboxId: "inbox-current").save(db, onConflict: .ignore)
        try DBInbox(
            inboxId: "inbox-current",
            clientId: "client-current",
            createdAt: Date()
        ).save(db, onConflict: .ignore)
        try DBConversation(
            id: conversationId,
            clientConversationId: "client-\(conversationId)",
            inviteTag: "tag-\(conversationId)",
            creatorId: "inbox-current",
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: false,
            hasHadVerifiedAgent: false
        ).insert(db)
    }

    private static func seedSummary(
        db: Database,
        createdAt: Date,
        prompt: String = "Be my assistant",
        bundledMessageIds: [String] = ["b-text"]
    ) throws {
        let idsJSON = String(data: try JSONEncoder().encode(bundledMessageIds), encoding: .utf8) ?? "[]"
        try DBAgentBuilderSummary(
            conversationId: conversationId,
            summaryId: UUID().uuidString,
            prompt: prompt,
            attachmentsJSON: "[]",
            createdAt: createdAt,
            cutoffDate: createdAt,
            bundledMessageIdsJSON: idsJSON,
            cloudConnectionIdsJSON: "{}"
        ).insert(db)
    }

    private static func seedBundledRow(db: Database, clientMessageId: String) throws {
        try DBMember(inboxId: "inbox-current").save(db, onConflict: .ignore)
        try DBMessage(
            id: clientMessageId,
            clientMessageId: clientMessageId,
            conversationId: conversationId,
            senderId: "inbox-current",
            dateNs: 1,
            date: Date(),
            sortId: nil,
            status: .published,
            messageType: .original,
            contentType: .text,
            text: "Be my assistant",
            emoji: nil,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: nil,
            attachmentUrls: [],
            update: nil
        ).insert(db)
    }

    @Test("Pre-process summary with no landed rows is pending")
    func interruptedBriefIsPending() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let processStart = Date()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db)
            try Self.seedSummary(db: db, createdAt: processStart.addingTimeInterval(-120))
        }
        let briefs = try dbManager.dbReader.read { db in
            try UnsentBuilderBriefReplayer.pendingBriefs(db: db, processStart: processStart, now: Date())
        }
        #expect(briefs.count == 1)
        #expect(briefs.first?.conversationId == Self.conversationId)
        #expect(briefs.first?.prompt == "Be my assistant")
        #expect(briefs.first?.textClientMessageId == "b-text")
    }

    @Test("Landed rows extinguish the pending brief")
    func landedRowsExtinguish() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let processStart = Date()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db)
            try Self.seedSummary(db: db, createdAt: processStart.addingTimeInterval(-120))
            try Self.seedBundledRow(db: db, clientMessageId: "b-text")
        }
        let briefs = try dbManager.dbReader.read { db in
            try UnsentBuilderBriefReplayer.pendingBriefs(db: db, processStart: processStart, now: Date())
        }
        #expect(briefs.isEmpty)
    }

    @Test("Summary created in this process is not replayed (send in flight)")
    func inFlightSummaryNotReplayed() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let processStart = Date().addingTimeInterval(-300)
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db)
            try Self.seedSummary(db: db, createdAt: processStart.addingTimeInterval(60))
        }
        let briefs = try dbManager.dbReader.read { db in
            try UnsentBuilderBriefReplayer.pendingBriefs(db: db, processStart: processStart, now: Date())
        }
        #expect(briefs.isEmpty)
    }

    @Test("Summaries older than the replay window are history, not pending")
    func oldSummaryNotReplayed() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let processStart = Date()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db)
            try Self.seedSummary(
                db: db,
                createdAt: processStart.addingTimeInterval(-(UnsentBuilderBriefReplayer.replayWindow + 60))
            )
        }
        let briefs = try dbManager.dbReader.read { db in
            try UnsentBuilderBriefReplayer.pendingBriefs(db: db, processStart: processStart, now: Date())
        }
        #expect(briefs.isEmpty)
    }

    @Test("Replayer start() sends pending briefs through the injected closure")
    func startSendsPendingBriefs() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let processStart = Date()
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db)
            try Self.seedSummary(db: db, createdAt: processStart.addingTimeInterval(-120))
        }
        let sent: OSAllocatedUnfairLockBox<[UnsentBuilderBriefReplayer.PendingBrief]> = .init([])
        let replayer = UnsentBuilderBriefReplayer(
            databaseReader: dbManager.dbReader,
            processStart: processStart
        ) { brief in
            sent.withLock { $0.append(brief) }
        }
        replayer.start()
        for _ in 0..<50 {
            if !sent.withLock({ $0 }).isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        replayer.stop()
        let briefs = sent.withLock { $0 }
        #expect(briefs.count == 1)
        #expect(briefs.first?.prompt == "Be my assistant")
    }
}

/// Tiny lock box for collecting values from a Sendable closure in tests.
private final class OSAllocatedUnfairLockBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
