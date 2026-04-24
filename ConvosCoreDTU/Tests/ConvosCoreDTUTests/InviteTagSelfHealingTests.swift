import ConvosAppData
@testable import ConvosCore
@testable import ConvosCoreDTU
import Foundation
import XCTest

/// Phase 2 batch 2: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/InviteTagSelfHealingTests.swift`.
///
/// Exercises the `MessagingGroup+CustomMetadata` self-healing rules:
///  - `ConversationWriter.store` preserves the local DB invite tag
///    when the incoming group's metadata has been cleared externally
///    (the row's `inviteTag` is the source of truth on restore).
///  - `restoreInviteTagIfMissing(_:)` refuses to install an invalid tag.
///
/// DTU unblocks in place:
///  - `appData` / `updateAppData` wired end-to-end on
///    `DTUMessagingGroup` (single-writer flows; concurrent-writer CAS is
///    a known DTU gap — see batch 2 brief).
///  - `ensureInviteTag` via `MessagingGroup+CustomMetadata` reaches
///    through `updateAppData` atomically for the single-client case.
///
/// No skips needed — the two tests here are single-writer flows.
final class InviteTagSelfHealingTests: XCTestCase {
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

    func testPreservesLocalInviteTagWhenIncomingTagIsEmpty() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "invite-self-heal-preserves"
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
        try await group.ensureInviteTag()
        let originalTag = try await group.inviteTag()

        let conversationWriter = ConversationWriter(
            identityStore: fixture.identityStore,
            databaseWriter: fixture.databaseManager.dbWriter,
            messageWriter: DualBackendMockIncomingMessageWriter()
        )

        _ = try await conversationWriter.store(conversation: group, inboxId: inboxIdA)

        // Simulate an external clearing of the custom-metadata blob.
        // Both backends round-trip the app-data string verbatim, so
        // pushing a metadata blob without a tag reproduces the "tag
        // was cleared upstream" scenario on either lane.
        let metadataWithoutTag = ConversationCustomMetadata()
        let encodedCleared = try metadataWithoutTag.toCompactString()
        try await group.updateAppData(encodedCleared)

        _ = try await conversationWriter.store(conversation: group, inboxId: inboxIdA)

        let storedConversation = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: group.id)
        }

        XCTAssertEqual(
            storedConversation?.inviteTag,
            originalTag,
            "[\(backend.rawValue)] stored invite tag must survive an external metadata clear"
        )
        let currentTag = try await group.inviteTag()
        XCTAssertEqual(
            currentTag,
            originalTag,
            "[\(backend.rawValue)] group's metadata tag should be self-healed back to the original"
        )
    }

    func testRestoreInviteTagRejectsInvalidFormat() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "invite-self-heal-invalid"
        )
        self.fixtures = fixture

        let alice = try await fixture.createClient()
        let bob = try await fixture.createClient()

        let group = try await alice.client.conversations.newGroup(
            withInboxIds: [bob.inboxAlias],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        do {
            try await group.restoreInviteTagIfMissing("bad-tag")
            XCTFail(
                "[\(backend.rawValue)] expected ConversationCustomMetadataError for invalid tag, "
                    + "got no throw"
            )
        } catch is ConversationCustomMetadataError {
            // expected
        }
    }
}
