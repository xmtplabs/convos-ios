@testable import ConvosCore
@testable import ConvosCoreDTU
import Foundation
import GRDB
import XCTest

/// Phase 2 batch 1: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/PendingInviteRepositoryTests.swift`.
///
/// `PendingInviteRepository` is a pure-DB query surface — it never
/// touches a `MessagingClient`. Migration onto `DualBackendTestFixtures`
/// is mechanical: replace the file-local `TestFixtures` + Swift
/// Testing suite with `DualBackendTestFixtures.databaseManager` and
/// XCTest. Both backends execute the same GRDB queries.
///
/// Also updates the `DBConversation` helper to pass the two fields
/// added since the original test was written (conversationEmoji,
/// hasHadVerifiedAssistant), restoring buildability for this suite.
final class PendingInviteRepositoryTests: XCTestCase {
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

    /// Boots a dual-backend fixture WITHOUT spinning up a messaging
    /// client. This repository suite is backend-agnostic; it only
    /// needs the shared database manager.
    private func bootDBOnlyFixture() -> DualBackendTestFixtures {
        let fixture = DualBackendTestFixtures(aliasPrefix: "pending-invite-repo")
        self.fixtures = fixture
        return fixture
    }

    // MARK: - Pending Invite Detection Tests

    func testHasPendingInvitesTrue() async throws {
        let fixtures = bootDBOnlyFixture()

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)

            // Draft conversation with invite tag (pending invite).
            try Self.makeDBConversation(
                id: "draft-123",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "invite-tag-abc"
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.databaseManager.dbReader)
        let hasPending = try repo.hasPendingInvites(clientId: "client-1")

        XCTAssertTrue(hasPending)
    }

    func testHasPendingInvitesFalseForNonDraft() async throws {
        let fixtures = bootDBOnlyFixture()

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)

            // Regular conversation (not draft) with invite tag.
            try Self.makeDBConversation(
                id: "convo-123",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "invite-tag-abc",
                consent: .allowed
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.databaseManager.dbReader)
        let hasPending = try repo.hasPendingInvites(clientId: "client-1")

        XCTAssertFalse(hasPending)
    }

    func testHasPendingInvitesFalseWithoutInviteTag() async throws {
        let fixtures = bootDBOnlyFixture()

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)

            // Draft conversation WITHOUT invite tag (not a pending invite).
            try Self.makeDBConversation(
                id: "draft-123",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: ""
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.databaseManager.dbReader)
        let hasPending = try repo.hasPendingInvites(clientId: "client-1")

        XCTAssertFalse(hasPending)
    }

    func testClientIdsWithPendingInvites() async throws {
        let fixtures = bootDBOnlyFixture()

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBInbox(inboxId: "inbox-2", clientId: "client-2", createdAt: Date()).insert(db)
            try DBInbox(inboxId: "inbox-3", clientId: "client-3", createdAt: Date()).insert(db)

            try Self.makeDBConversation(
                id: "draft-1",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "tag-1"
            ).insert(db)

            try Self.makeDBConversation(
                id: "convo-2",
                inboxId: "inbox-2",
                clientId: "client-2",
                inviteTag: "",
                consent: .allowed
            ).insert(db)

            try Self.makeDBConversation(
                id: "draft-3",
                inboxId: "inbox-3",
                clientId: "client-3",
                inviteTag: "tag-3"
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.databaseManager.dbReader)
        let clientIds = try repo.clientIdsWithPendingInvites()

        XCTAssertEqual(clientIds.count, 2)
        XCTAssertTrue(clientIds.contains("client-1"))
        XCTAssertTrue(clientIds.contains("client-3"))
        XCTAssertFalse(clientIds.contains("client-2"))
    }

    func testAllPendingInvites() async throws {
        let fixtures = bootDBOnlyFixture()

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBInbox(inboxId: "inbox-2", clientId: "client-2", createdAt: Date()).insert(db)

            try Self.makeDBConversation(
                id: "draft-1a",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "tag-1a"
            ).insert(db)

            try Self.makeDBConversation(
                id: "draft-1b",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "tag-1b"
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.databaseManager.dbReader)
        let infos = try repo.allPendingInvites()

        let client1Info = infos.first { $0.clientId == "client-1" }
        let client2Info = infos.first { $0.clientId == "client-2" }

        XCTAssertNotNil(client1Info)
        XCTAssertEqual(client1Info?.hasPendingInvites, true)
        XCTAssertEqual(client1Info?.pendingConversationIds.count, 2)

        XCTAssertNotNil(client2Info)
        XCTAssertEqual(client2Info?.hasPendingInvites, false)
    }

    // MARK: - DB Row Helpers

    static func makeDBConversation(
        id: String,
        inboxId: String,
        clientId: String,
        inviteTag: String,
        consent: Consent = .unknown
    ) -> DBConversation {
        DBConversation(
            id: id,
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: id,
            inviteTag: inviteTag,
            creatorId: inboxId,
            kind: .group,
            consent: consent,
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
            hasHadVerifiedAssistant: false
        )
    }
}
