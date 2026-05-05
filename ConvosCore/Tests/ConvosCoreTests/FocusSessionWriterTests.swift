@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("FocusSessionWriter")
struct FocusSessionWriterTests {
    @Test("FocusModeControl(.start) inserts a started session")
    func testStartInsertsSession() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(id: "conv-1").insert(db)
        }
        let writer = FocusSessionWriter(databaseWriter: dbManager.dbWriter)

        try await writer.applyFocusModeControl(
            .init(state: .start, focusedInboxId: "agent-1", sessionId: "session-A"),
            conversationId: "conv-1"
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBFocusSession.filter(Column("sessionId") == "session-A").fetchOne(db)
        }
        #expect(stored?.state == .started)
        #expect(stored?.focusedInboxId == "agent-1")
        #expect(stored?.conversationId == "conv-1")
        #expect(stored?.stoppedAt == nil)
    }

    @Test("FocusModeControl(.start) with nil focusedInboxId is allowed and persists nil")
    func testStartWithNilFocus() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(id: "conv-1").insert(db)
        }
        let writer = FocusSessionWriter(databaseWriter: dbManager.dbWriter)

        try await writer.applyFocusModeControl(
            .init(state: .start, focusedInboxId: nil, sessionId: "session-pending"),
            conversationId: "conv-1"
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBFocusSession.filter(Column("sessionId") == "session-pending").fetchOne(db)
        }
        #expect(stored?.focusedInboxId == nil)
        #expect(stored?.state == .started)
    }

    @Test("Re-broadcast .start with a known focusedInboxId promotes a pending session")
    func testStartPromotesPendingSession() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(id: "conv-1").insert(db)
        }
        let writer = FocusSessionWriter(databaseWriter: dbManager.dbWriter)

        try await writer.applyFocusModeControl(
            .init(state: .start, focusedInboxId: nil, sessionId: "session-X"),
            conversationId: "conv-1"
        )
        try await writer.applyFocusModeControl(
            .init(state: .start, focusedInboxId: "agent-2", sessionId: "session-X"),
            conversationId: "conv-1"
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBFocusSession.filter(Column("sessionId") == "session-X").fetchOne(db)
        }
        #expect(stored?.focusedInboxId == "agent-2")
        #expect(stored?.state == .started)
    }

    @Test("Stale .start with nil focusedInboxId never overwrites a known focus")
    func testStaleNilDoesNotOverwriteKnownFocus() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(id: "conv-1").insert(db)
        }
        let writer = FocusSessionWriter(databaseWriter: dbManager.dbWriter)

        try await writer.applyFocusModeControl(
            .init(state: .start, focusedInboxId: "agent-1", sessionId: "session-Y"),
            conversationId: "conv-1"
        )
        try await writer.applyFocusModeControl(
            .init(state: .start, focusedInboxId: nil, sessionId: "session-Y"),
            conversationId: "conv-1"
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBFocusSession.filter(Column("sessionId") == "session-Y").fetchOne(db)
        }
        #expect(stored?.focusedInboxId == "agent-1")
    }

    @Test("FocusModeControl(.stop) marks the session stopped with a stoppedAt date")
    func testStopMarksSession() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(id: "conv-1").insert(db)
        }
        let writer = FocusSessionWriter(databaseWriter: dbManager.dbWriter)

        try await writer.applyFocusModeControl(
            .init(state: .start, focusedInboxId: "agent-1", sessionId: "session-Z"),
            conversationId: "conv-1"
        )
        try await writer.applyFocusModeControl(
            .init(state: .stop, focusedInboxId: nil, sessionId: "session-Z"),
            conversationId: "conv-1"
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBFocusSession.filter(Column("sessionId") == "session-Z").fetchOne(db)
        }
        #expect(stored?.state == .stopped)
        #expect(stored?.stoppedAt != nil)
    }

    @Test("StreamingText upserts the live bubble for the sender")
    func testStreamingTextUpserts() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(id: "conv-1").insert(db)
        }
        let writer = FocusSessionWriter(databaseWriter: dbManager.dbWriter)

        try await writer.applyFocusModeControl(
            .init(state: .start, focusedInboxId: "agent-1", sessionId: "session-text"),
            conversationId: "conv-1"
        )
        try await writer.applyStreamingText(
            .init(sessionId: "session-text", senderInboxId: "user-1", revision: 1, text: "hi")
        )
        try await writer.applyStreamingText(
            .init(sessionId: "session-text", senderInboxId: "user-1", revision: 2, text: "hi there")
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBLiveBubble
                .filter(Column("sessionId") == "session-text" && Column("senderInboxId") == "user-1")
                .fetchOne(db)
        }
        #expect(stored?.text == "hi there")
        #expect(stored?.revision == 2)
    }

    @Test("StreamingText with stale revision is dropped")
    func testStreamingTextStaleRevisionDropped() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(id: "conv-1").insert(db)
        }
        let writer = FocusSessionWriter(databaseWriter: dbManager.dbWriter)

        try await writer.applyFocusModeControl(
            .init(state: .start, focusedInboxId: "agent-1", sessionId: "session-stale"),
            conversationId: "conv-1"
        )
        try await writer.applyStreamingText(
            .init(sessionId: "session-stale", senderInboxId: "user-1", revision: 5, text: "newest")
        )
        try await writer.applyStreamingText(
            .init(sessionId: "session-stale", senderInboxId: "user-1", revision: 3, text: "stale")
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBLiveBubble
                .filter(Column("sessionId") == "session-stale" && Column("senderInboxId") == "user-1")
                .fetchOne(db)
        }
        #expect(stored?.text == "newest")
        #expect(stored?.revision == 5)
    }

    @Test("StreamingText for a stopped session is dropped")
    func testStreamingTextDroppedForStoppedSession() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(id: "conv-1").insert(db)
        }
        let writer = FocusSessionWriter(databaseWriter: dbManager.dbWriter)

        try await writer.applyFocusModeControl(
            .init(state: .start, focusedInboxId: "agent-1", sessionId: "session-stopped"),
            conversationId: "conv-1"
        )
        try await writer.applyFocusModeControl(
            .init(state: .stop, focusedInboxId: nil, sessionId: "session-stopped"),
            conversationId: "conv-1"
        )
        try await writer.applyStreamingText(
            .init(sessionId: "session-stopped", senderInboxId: "user-1", revision: 1, text: "late")
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBLiveBubble
                .filter(Column("sessionId") == "session-stopped").fetchOne(db)
        }
        #expect(stored == nil)
    }

    @Test("StreamingClear blanks the bubble after the receiver delay")
    func testStreamingClearBlanks() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(id: "conv-1").insert(db)
        }
        let writer = FocusSessionWriter(databaseWriter: dbManager.dbWriter)

        try await writer.applyFocusModeControl(
            .init(state: .start, focusedInboxId: "agent-1", sessionId: "session-clear"),
            conversationId: "conv-1"
        )
        try await writer.applyStreamingText(
            .init(sessionId: "session-clear", senderInboxId: "user-1", revision: 1, text: "draft")
        )
        // Receiver delays the clear by ~600ms so the final phrase stays readable.
        // Awaiting applyStreamingClear blocks until after the delay completes.
        try await writer.applyStreamingClear(
            .init(sessionId: "session-clear", senderInboxId: "user-1", revision: 2)
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBLiveBubble
                .filter(Column("sessionId") == "session-clear" && Column("senderInboxId") == "user-1")
                .fetchOne(db)
        }
        #expect(stored?.text == "")
        #expect(stored?.revision == 2)
    }

    @Test("StreamingClear is dropped if a newer StreamingText arrives during the receiver delay")
    func testStreamingClearDroppedByConcurrentNewerText() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(id: "conv-1").insert(db)
        }
        let writer = FocusSessionWriter(databaseWriter: dbManager.dbWriter)

        try await writer.applyFocusModeControl(
            .init(state: .start, focusedInboxId: "agent-1", sessionId: "session-race"),
            conversationId: "conv-1"
        )
        try await writer.applyStreamingText(
            .init(sessionId: "session-race", senderInboxId: "user-1", revision: 1, text: "draft")
        )

        // Kick off the clear; while it sleeps, fire a newer streaming text.
        async let clearTask: Void = writer.applyStreamingClear(
            .init(sessionId: "session-race", senderInboxId: "user-1", revision: 2)
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        try await writer.applyStreamingText(
            .init(sessionId: "session-race", senderInboxId: "user-1", revision: 3, text: "kept!")
        )
        try await clearTask

        let stored = try await dbManager.dbReader.read { db in
            try DBLiveBubble
                .filter(Column("sessionId") == "session-race" && Column("senderInboxId") == "user-1")
                .fetchOne(db)
        }
        #expect(stored?.text == "kept!")
        #expect(stored?.revision == 3)
    }

    @Test("Stop preserves existing live bubbles in place")
    func testStopPreservesBubbles() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(id: "conv-1").insert(db)
        }
        let writer = FocusSessionWriter(databaseWriter: dbManager.dbWriter)

        try await writer.applyFocusModeControl(
            .init(state: .start, focusedInboxId: "agent-1", sessionId: "session-keep"),
            conversationId: "conv-1"
        )
        try await writer.applyStreamingText(
            .init(sessionId: "session-keep", senderInboxId: "user-1", revision: 1, text: "kept")
        )
        try await writer.applyFocusModeControl(
            .init(state: .stop, focusedInboxId: nil, sessionId: "session-keep"),
            conversationId: "conv-1"
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBLiveBubble
                .filter(Column("sessionId") == "session-keep" && Column("senderInboxId") == "user-1")
                .fetchOne(db)
        }
        #expect(stored?.text == "kept")
    }

    private func makeDBConversation(id: String) -> DBConversation {
        DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: "invite-\(id)",
            creatorId: "test-inbox",
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
            hasHadVerifiedAssistant: false,
        )
    }
}

@Suite("FocusModeCodecs")
struct FocusModeCodecTests {
    @Test("FocusModeControl round-trips with optional focusedInboxId")
    func testFocusModeControlRoundTripOptional() throws {
        let codec = FocusModeControlCodec()
        let withId = FocusModeControl(state: .start, focusedInboxId: "abc", sessionId: "s1")
        let withoutId = FocusModeControl(state: .start, focusedInboxId: nil, sessionId: "s2")

        let decodedWithId = try codec.decode(content: codec.encode(content: withId))
        let decodedWithoutId = try codec.decode(content: codec.encode(content: withoutId))

        #expect(decodedWithId.focusedInboxId == "abc")
        #expect(decodedWithId.state == .start)
        #expect(decodedWithoutId.focusedInboxId == nil)
    }

    @Test("StreamingText round-trips snapshot text + revision")
    func testStreamingTextRoundTrip() throws {
        let codec = StreamingTextCodec()
        let payload = StreamingText(sessionId: "s", senderInboxId: "u", revision: 42, text: "hello world")
        let decoded = try codec.decode(content: codec.encode(content: payload))
        #expect(decoded.text == "hello world")
        #expect(decoded.revision == 42)
    }

    @Test("StreamingClear round-trips revision")
    func testStreamingClearRoundTrip() throws {
        let codec = StreamingClearCodec()
        let payload = StreamingClear(sessionId: "s", senderInboxId: "u", revision: 7)
        let decoded = try codec.decode(content: codec.encode(content: payload))
        #expect(decoded.revision == 7)
    }

    @Test("All three codecs report shouldPush == false")
    func testShouldPushFalse() throws {
        let focus = FocusModeControl(state: .start, focusedInboxId: nil, sessionId: "s")
        let text = StreamingText(sessionId: "s", senderInboxId: "u", revision: 1, text: "")
        let clear = StreamingClear(sessionId: "s", senderInboxId: "u", revision: 1)
        #expect(try FocusModeControlCodec().shouldPush(content: focus) == false)
        #expect(try StreamingTextCodec().shouldPush(content: text) == false)
        #expect(try StreamingClearCodec().shouldPush(content: clear) == false)
    }
}
