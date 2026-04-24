@testable import ConvosCore
@testable import ConvosCoreDTU
import Foundation
import XCTest

/// Phase 2 batch 2: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/ClientConversationIdPriorityTests.swift`.
///
/// Tests for `clientConversationId` priority logic in `ConversationWriter`.
/// When a conversation is saved and there's an existing row with the
/// same inviteTag but a different `clientConversationId`, the writer
/// applies this priority:
///  1. If the incoming id has the `draft-` prefix, the incoming id wins.
///  2. Otherwise the existing id is kept.
///
/// This ensures draft IDs (used for image caching and the default-emoji
/// deterministic pick) are preserved regardless of the order in which
/// stream processing and explicit conversation creation happen.
///
/// DTU unblock: the writer's `_store(...)` reads
/// `conversation.creatorInboxId()` unconditionally; that was added to
/// `DTUMessagingGroup` in the creatorInboxId end-to-end work that landed
/// before this batch. Without it, DTU threw inside the first call and
/// the store path was unreachable — hence migrating this suite now.
///
/// The three integration tests run against whichever backend
/// `CONVOS_MESSAGING_BACKEND` selects; the three pure-unit `isDraft`
/// tests don't touch the backend.
final class ClientConversationIdPriorityTests: XCTestCase {
    private var fixtures: DualBackendTestFixtures?

    override func tearDown() async throws {
        if let fixtures {
            try? await fixtures.cleanup()
            self.fixtures = nil
        }
        try await super.tearDown()
    }

    override class func tearDown() {
        Task {
            await DualBackendTestFixtures.tearDownSharedDTUIfNeeded()
        }
        super.tearDown()
    }

    /// XMTPiOS backend requires the Docker-backed XMTP node. Skip the
    /// run cleanly instead of flaking when the env var isn't set.
    private func guardBackendReady(_ backend: DualBackendTestFixtures.Backend) throws {
        if backend == .xmtpiOS,
           ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] == nil {
            throw XCTSkip(
                "CONVOS_MESSAGING_BACKEND=\(backend.rawValue) (default) and "
                    + "XMTP_NODE_ADDRESS is unset; skipping to avoid a network-"
                    + "dependent failure. Start the XMTP Docker stack or set "
                    + "CONVOS_MESSAGING_BACKEND=dtu."
            )
        }
    }

    // MARK: - DBConversation.isDraft Tests (pure-unit)

    func testIsDraftReturnsTrueForDraftPrefix() {
        let draftId = DBConversation.generateDraftConversationId()
        XCTAssertTrue(DBConversation.isDraft(id: draftId))
        XCTAssertTrue(draftId.hasPrefix("draft-"))
    }

    func testIsDraftReturnsFalseForXMTPIds() {
        let xmtpId = "ab0072d354857faceec1d5864e259ac1"
        XCTAssertFalse(DBConversation.isDraft(id: xmtpId))
    }

    func testIsDraftReturnsFalseForUUIDs() {
        let uuidId = UUID().uuidString
        XCTAssertFalse(DBConversation.isDraft(id: uuidId))
    }

    func testGenerateDraftConversationIdCreatesUniqueIds() {
        let id1 = DBConversation.generateDraftConversationId()
        let id2 = DBConversation.generateDraftConversationId()
        XCTAssertNotEqual(id1, id2)
        XCTAssertTrue(DBConversation.isDraft(id: id1))
        XCTAssertTrue(DBConversation.isDraft(id: id2))
    }

    // MARK: - Integration Tests (ConversationWriter)

    func testStoreWithDraftIdAfterStreamPreservesDraftId() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "ccid-draft-after-stream"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let bob = try await fixture.createClient()
        let inboxIdA = alice.inboxAlias
        let clientIdA = alice.clientId

        // Insert inbox into database (required by ConversationWriter)
        try await fixture.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date())
                .insert(db)
        }

        // Create a group via the Messaging surface so both backends stay
        // on the same code path.
        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [bob.inboxAlias],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        let conversationId = group.id

        // Create ConversationWriter
        let mockMessageWriter = DualBackendMockIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixture.identityStore,
            databaseWriter: fixture.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )

        // First store: simulate stream processing (uses backend group id
        // as clientConversationId)
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil // Stream doesn't pass a draft ID
        )

        // Verify initial clientConversationId equals the conversation id
        let afterStream = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        XCTAssertEqual(
            afterStream?.clientConversationId,
            conversationId,
            "[\(backend.rawValue)] initial stream store should set clientConversationId = group.id"
        )

        // Second store: simulate explicit creation with a draft id
        let draftId = DBConversation.generateDraftConversationId()
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: draftId
        )

        // Verify draft id took priority
        let afterExplicit = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        XCTAssertEqual(
            afterExplicit?.clientConversationId,
            draftId,
            "[\(backend.rawValue)] draft id should override non-draft on subsequent store"
        )
    }

    func testStoreWithXmtpIdAfterDraftPreservesDraftId() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "ccid-stream-after-draft"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let bob = try await fixture.createClient()
        let inboxIdA = alice.inboxAlias
        let clientIdA = alice.clientId

        try await fixture.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date())
                .insert(db)
        }

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [bob.inboxAlias],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        let conversationId = group.id

        let mockMessageWriter = DualBackendMockIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixture.identityStore,
            databaseWriter: fixture.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )

        // First store: simulate explicit creation with a draft id
        let draftId = DBConversation.generateDraftConversationId()
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: draftId
        )

        // Verify draft id was stored
        let afterExplicit = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        XCTAssertEqual(
            afterExplicit?.clientConversationId,
            draftId,
            "[\(backend.rawValue)] first draft store should persist draft id"
        )

        // Second store: simulate stream processing (no draft id)
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        // Verify draft id was preserved (not overwritten by stream)
        let afterStream = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        XCTAssertEqual(
            afterStream?.clientConversationId,
            draftId,
            "[\(backend.rawValue)] subsequent stream store must not overwrite draft id"
        )
    }

    func testMultipleStoresWithoutDraftKeepFirst() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "ccid-multiple-nondraft"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let bob = try await fixture.createClient()
        let inboxIdA = alice.inboxAlias
        let clientIdA = alice.clientId

        try await fixture.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date())
                .insert(db)
        }

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [bob.inboxAlias],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        let conversationId = group.id

        let mockMessageWriter = DualBackendMockIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixture.identityStore,
            databaseWriter: fixture.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )

        // First store without draft id
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        let afterFirst = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        let firstClientConversationId = afterFirst?.clientConversationId
        XCTAssertEqual(
            firstClientConversationId,
            conversationId,
            "[\(backend.rawValue)] initial non-draft store should adopt group id"
        )

        // Second store without draft id (simulates another stream event)
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        // Verify original clientConversationId was preserved
        let afterSecond = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        XCTAssertEqual(
            afterSecond?.clientConversationId,
            firstClientConversationId,
            "[\(backend.rawValue)] second non-draft store should not churn clientConversationId"
        )
    }
}
