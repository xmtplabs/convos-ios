@testable import ConvosCore
@testable import ConvosCoreDTU
import ConvosMessagingProtocols
import Foundation
import GRDB
import XCTest

/// Minimal stand-in for `IncomingMessageWriter` that short-circuits
/// `store(...)` without touching the database. Matches the current
/// `MessagingMessage`-flavored protocol in ConvosCore (the legacy
/// `XMTPiOS.DecodedMessage` version in `LockConversationTests.swift`
/// is out-of-date for the present branch). We keep it file-local so the
/// migration doesn't drag a larger test-support surface across modules.
private final class StubIncomingMessageWriter: IncomingMessageWriterProtocol,
                                               @unchecked Sendable {
    func store(
        message: MessagingMessage,
        for conversation: DBConversation
    ) async throws -> IncomingMessageWriterResult {
        IncomingMessageWriterResult(
            contentType: .text,
            wasRemovedFromConversation: false,
            messageAlreadyExists: false
        )
    }

    func decodeExplodeSettings(from message: MessagingMessage) -> ExplodeSettings? {
        nil
    }

    func processExplodeSettings(
        _ settings: ExplodeSettings,
        conversationId: String,
        senderInboxId: String,
        currentInboxId: String
    ) async -> ExplodeSettingsResult {
        .fromSelf
    }
}

/// Phase 2: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/ConsumedConversationCreatedAtTests.swift`.
///
/// Exercises `ConversationWriter.store(...)` — the writer at the heart of
/// every Convos integration path. The legacy version anchored on
/// `fixtures.clientA as? Client` (real XMTPiOS `Client`); this rewrite
/// drives the writer through the `any MessagingClient` +
/// `any MessagingGroup` abstraction so both backends run the same code.
///
/// The DTU unblock that made this migration possible is the
/// `creatorInboxId` surface: `ConversationWriter._store(...)` calls
/// `conversation.creatorInboxId()` unconditionally, and
/// `DTUMessagingGroup.creatorInboxId()` previously threw. With that
/// field wired end-to-end (engine → wire → SDK → adapter) the store
/// path is now traversable on DTU.
final class ConsumedConversationCreatedAtTests: XCTestCase {
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
    /// run cleanly instead of flaking when the env var isn't set, matching
    /// the pattern used in `CreateGroupSendListCrossBackendTests`.
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

    // MARK: - Re-storing a consumed conversation preserves its createdAt

    func testRestorePreservesCreatedAtForConsumedConversation() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "consumed-preserves"
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

        // Creating through `MessagingConversations.newGroup` keeps the
        // test free of any XMTPiOS type leakage. DTU's adapter
        // forwards to `create_group` with the caller as creator inbox.
        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [inboxIdA, bob.inboxAlias],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        let conversationId = group.id

        let mockMessageWriter = StubIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixture.identityStore,
            databaseWriter: fixture.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        let xmtpCreatedAt = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)?.createdAt
        }
        XCTAssertNotNil(xmtpCreatedAt, "[\(backend.rawValue)] initial store should seed createdAt")

        let consumedAt = Date()
        try await fixture.databaseManager.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE conversation SET isUnused = ?, createdAt = ? WHERE id = ?",
                arguments: [false, consumedAt, conversationId]
            )
        }

        let afterConsume = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        XCTAssertEqual(
            afterConsume?.isUnused,
            false,
            "[\(backend.rawValue)] consume should clear isUnused"
        )
        let storedConsumedAt = try XCTUnwrap(afterConsume?.createdAt)
        XCTAssertLessThan(
            abs(storedConsumedAt.timeIntervalSince(consumedAt)),
            1,
            "[\(backend.rawValue)] consumed-at should be stored verbatim"
        )

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        let afterRestore = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        let finalCreatedAt = try XCTUnwrap(afterRestore?.createdAt)
        XCTAssertLessThan(
            abs(finalCreatedAt.timeIntervalSince(consumedAt)),
            1,
            "[\(backend.rawValue)] restore on consumed conversation must preserve createdAt"
        )
    }

    // MARK: - Re-storing an unused conversation does NOT preserve createdAt

    func testRestoreDoesNotPreserveCreatedAtForUnusedConversation() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "consumed-unused"
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
            withInboxIds: [inboxIdA, bob.inboxAlias],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        let conversationId = group.id

        let mockMessageWriter = StubIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixture.identityStore,
            databaseWriter: fixture.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        try await fixture.databaseManager.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE conversation SET isUnused = ? WHERE id = ?",
                arguments: [true, conversationId]
            )
        }

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        let afterRestore = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        let finalCreatedAt = try XCTUnwrap(afterRestore?.createdAt)
        // The conversation's `createdAtNs` is the abstraction's source
        // of truth: DTU synthesizes a stable value at group construction
        // time (see DTUMessagingGroup.assignedCreatedAtNs); XMTPiOS
        // surfaces libxmtp's real MLS `createdAt`. Either way the
        // restore over an unused conversation rewrites with that value.
        let groupCreatedAt = Date(timeIntervalSince1970: Double(group.createdAtNs) / 1_000_000_000)
        XCTAssertLessThan(
            abs(finalCreatedAt.timeIntervalSince(groupCreatedAt)),
            1,
            "[\(backend.rawValue)] restore on unused conversation should adopt group.createdAt"
        )
    }
}
