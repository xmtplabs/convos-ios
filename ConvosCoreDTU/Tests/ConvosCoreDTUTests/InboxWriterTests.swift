@testable import ConvosCore
@testable import ConvosCoreDTU
import ConvosMessagingProtocols
import Foundation
import GRDB
import XCTest

/// Phase 2 batch 1: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/InboxWriterTests.swift`.
///
/// `InboxWriter` is a pure-DB writer — it never touches a `MessagingClient`.
/// The migration here is mechanical: swap `TestFixtures` (legacy
/// `any XMTPClientProvider` surface) for `DualBackendTestFixtures`
/// (`any MessagingClient` surface), keep everything else identical.
///
/// Because the writer is backend-agnostic, BOTH backends execute the
/// exact same code path through GRDB. We still parameterise on
/// `DualBackendTestFixtures.Backend.selected` so the run shows up in
/// both the DTU and XMTPiOS lanes, proving the shared writer surface
/// doesn't depend on the messaging backend.
///
/// Tests cover:
/// - Saving new inbox
/// - Detecting clientId mismatch (invariant violation)
/// - Idempotent saves with matching clientId
/// - Delete by inboxId / by clientId
final class InboxWriterTests: XCTestCase {
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
    /// client — this writer suite never needs one. Skipping client
    /// creation keeps the test fast (no DTU subprocess handshake, no
    /// XMTP Docker roundtrip) and avoids the `XMTP_NODE_ADDRESS`
    /// dependency even on the XMTPiOS lane.
    private func bootDBOnlyFixture() -> DualBackendTestFixtures {
        let fixture = DualBackendTestFixtures(aliasPrefix: "inboxwriter")
        self.fixtures = fixture
        return fixture
    }

    func testSaveNewInbox() async throws {
        let fixtures = bootDBOnlyFixture()
        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)

        let inboxId = "test-inbox-id"
        let clientId = ClientId.generate().value

        let savedInbox = try await inboxWriter.save(inboxId: inboxId, clientId: clientId)

        XCTAssertEqual(savedInbox.inboxId, inboxId)
        XCTAssertEqual(savedInbox.clientId, clientId)

        let dbInbox = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: inboxId)
        }

        XCTAssertNotNil(dbInbox)
        XCTAssertEqual(dbInbox?.clientId, clientId)
    }

    func testSaveIdempotentWithMatchingClientId() async throws {
        let fixtures = bootDBOnlyFixture()
        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)

        let inboxId = "test-inbox-id"
        let clientId = ClientId.generate().value

        let firstSave = try await inboxWriter.save(inboxId: inboxId, clientId: clientId)
        let secondSave = try await inboxWriter.save(inboxId: inboxId, clientId: clientId)

        XCTAssertEqual(firstSave.inboxId, secondSave.inboxId)
        XCTAssertEqual(firstSave.clientId, secondSave.clientId)

        let dbInboxes = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchAll(db)
        }

        XCTAssertEqual(dbInboxes.count, 1)
    }

    func testSaveThrowsOnClientIdMismatch() async throws {
        let fixtures = bootDBOnlyFixture()
        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)

        let inboxId = "test-inbox-id"
        let originalClientId = ClientId.generate().value
        let differentClientId = ClientId.generate().value

        _ = try await inboxWriter.save(inboxId: inboxId, clientId: originalClientId)

        do {
            _ = try await inboxWriter.save(inboxId: inboxId, clientId: differentClientId)
            XCTFail("Expected InboxWriterError.clientIdMismatch, got no throw")
        } catch is InboxWriterError {
            // expected
        }

        let dbInbox = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: inboxId)
        }
        XCTAssertEqual(dbInbox?.clientId, originalClientId)
    }

    func testDeleteInbox() async throws {
        let fixtures = bootDBOnlyFixture()
        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)

        let inboxId = "test-inbox-id"
        let clientId = ClientId.generate().value

        _ = try await inboxWriter.save(inboxId: inboxId, clientId: clientId)

        var dbInbox = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: inboxId)
        }
        XCTAssertNotNil(dbInbox)

        try await inboxWriter.delete(inboxId: inboxId)

        dbInbox = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: inboxId)
        }
        XCTAssertNil(dbInbox)
    }

    func testDeleteByClientId() async throws {
        let fixtures = bootDBOnlyFixture()
        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)

        let inboxId = "test-inbox-id"
        let clientId = ClientId.generate().value

        _ = try await inboxWriter.save(inboxId: inboxId, clientId: clientId)

        try await inboxWriter.delete(clientId: clientId)

        let dbInbox = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: inboxId)
        }
        XCTAssertNil(dbInbox)
    }
}
