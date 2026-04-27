@testable import ConvosCore
@testable import ConvosCoreDTU
import ConvosMessagingProtocols
import Foundation
import GRDB
import XCTest

/// Phase 2 batch 1: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/PendingPhotoUploadTests.swift`.
///
/// Exercises GRDB CRUD on `DBPendingPhotoUpload`. Pure-DB, no
/// `MessagingClient` involvement. Migrating onto
/// `DualBackendTestFixtures` reuses the shared database manager and
/// XCTest tearDown conventions already established by the rest of
/// the ConvosCoreDTU test suite. Both backends execute the exact
/// same GRDB code paths.
///
/// Also restores buildability by adding the `conversationEmoji` /
/// `hasHadVerifiedAssistant` params to the `DBConversation` helper —
/// the original file was already broken on this branch for the
/// same reason as other ConvosCore tests that still construct
/// DBConversation directly.
final class PendingPhotoUploadTests: XCTestCase {
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

    /// Boots a DB-only fixture — no messaging client, no DTU
    /// subprocess handshake, no Docker dependency.
    private func bootDBOnlyFixture() -> DualBackendTestFixtures {
        let fixture = DualBackendTestFixtures(aliasPrefix: "pending-photo-upload")
        self.fixtures = fixture
        return fixture
    }

    func testInsertAndFetch() async throws {
        let fixtures = bootDBOnlyFixture()
        let dbManager = fixtures.databaseManager

        let upload = DBPendingPhotoUpload(
            id: "task-123",
            clientMessageId: "msg-456",
            conversationId: "conv-789",
            localCacheURL: "file:///cache/photo.jpg",
            state: .uploading,
            createdAt: Date(),
            updatedAt: Date()
        )

        try await dbManager.dbWriter.write { db in
            try Self.makeDBConversation(id: "conv-789").insert(db)
            try upload.insert(db)
        }

        let fetched = try await dbManager.dbReader.read { db in
            try DBPendingPhotoUpload.fetchOne(db, key: "task-123")
        }

        XCTAssertEqual(fetched?.clientMessageId, "msg-456")
        XCTAssertEqual(fetched?.state, .uploading)
    }

    func testUpdateStateToFailed() async throws {
        let fixtures = bootDBOnlyFixture()
        let dbManager = fixtures.databaseManager

        let upload = DBPendingPhotoUpload(
            id: "task-123",
            clientMessageId: "msg-456",
            conversationId: "conv-789",
            localCacheURL: "file:///cache/photo.jpg",
            state: .uploading,
            createdAt: Date(),
            updatedAt: Date()
        )

        try await dbManager.dbWriter.write { db in
            try Self.makeDBConversation(id: "conv-789").insert(db)
            try upload.insert(db)
        }

        _ = try await dbManager.dbWriter.write { db in
            try DBPendingPhotoUpload
                .filter(key: "task-123")
                .updateAll(
                    db,
                    DBPendingPhotoUpload.Columns.state.set(to: PendingUploadState.failed.rawValue),
                    DBPendingPhotoUpload.Columns.errorMessage.set(to: "Network timeout")
                )
        }

        let fetched = try await dbManager.dbReader.read { db in
            try DBPendingPhotoUpload.fetchOne(db, key: "task-123")
        }

        XCTAssertEqual(fetched?.state, .failed)
        XCTAssertEqual(fetched?.errorMessage, "Network timeout")
    }

    func testDelete() async throws {
        let fixtures = bootDBOnlyFixture()
        let dbManager = fixtures.databaseManager

        let upload = DBPendingPhotoUpload(
            id: "task-123",
            clientMessageId: "msg-456",
            conversationId: "conv-789",
            localCacheURL: "file:///cache/photo.jpg",
            state: .completed,
            createdAt: Date(),
            updatedAt: Date()
        )

        try await dbManager.dbWriter.write { db in
            try Self.makeDBConversation(id: "conv-789").insert(db)
            try upload.insert(db)
        }

        _ = try await dbManager.dbWriter.write { db in
            try DBPendingPhotoUpload.deleteOne(db, key: "task-123")
        }

        let fetched = try await dbManager.dbReader.read { db in
            try DBPendingPhotoUpload.fetchOne(db, key: "task-123")
        }

        XCTAssertNil(fetched)
    }

    func testFetchByState() async throws {
        let fixtures = bootDBOnlyFixture()
        let dbManager = fixtures.databaseManager

        let uploading = DBPendingPhotoUpload(
            id: "task-1",
            clientMessageId: "msg-1",
            conversationId: "conv-1",
            localCacheURL: "file:///cache/photo1.jpg",
            state: .uploading
        )
        let failed = DBPendingPhotoUpload(
            id: "task-2",
            clientMessageId: "msg-2",
            conversationId: "conv-1",
            localCacheURL: "file:///cache/photo2.jpg",
            state: .failed,
            errorMessage: "Upload failed"
        )
        let completed = DBPendingPhotoUpload(
            id: "task-3",
            clientMessageId: "msg-3",
            conversationId: "conv-1",
            localCacheURL: "file:///cache/photo3.jpg",
            state: .completed
        )

        try await dbManager.dbWriter.write { db in
            try Self.makeDBConversation(id: "conv-1").insert(db)
            try uploading.insert(db)
            try failed.insert(db)
            try completed.insert(db)
        }

        let failedUploads = try await dbManager.dbReader.read { db in
            try DBPendingPhotoUpload
                .filter(DBPendingPhotoUpload.Columns.state == PendingUploadState.failed.rawValue)
                .fetchAll(db)
        }

        XCTAssertEqual(failedUploads.count, 1)
        XCTAssertEqual(failedUploads.first?.id, "task-2")
    }

    // MARK: - DB Row Helpers

    static func makeDBConversation(id: String) -> DBConversation {
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
