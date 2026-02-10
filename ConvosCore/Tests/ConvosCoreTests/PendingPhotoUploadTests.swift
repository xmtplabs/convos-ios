@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("PendingPhotoUpload Tests")
struct PendingPhotoUploadTests {
    @Test("Can insert and fetch pending upload")
    func testInsertAndFetch() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

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
            try makeDBConversation(id: "conv-789").insert(db)
            try upload.insert(db)
        }

        let fetched = try await dbManager.dbReader.read { db in
            try DBPendingPhotoUpload.fetchOne(db, key: "task-123")
        }

        #expect(fetched?.clientMessageId == "msg-456")
        #expect(fetched?.state == .uploading)
    }

    @Test("Can update state to failed with error message")
    func testUpdateStateToFailed() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

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
            try makeDBConversation(id: "conv-789").insert(db)
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

        #expect(fetched?.state == .failed)
        #expect(fetched?.errorMessage == "Network timeout")
    }

    @Test("Can delete pending upload")
    func testDelete() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

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
            try makeDBConversation(id: "conv-789").insert(db)
            try upload.insert(db)
        }

        _ = try await dbManager.dbWriter.write { db in
            try DBPendingPhotoUpload.deleteOne(db, key: "task-123")
        }

        let fetched = try await dbManager.dbReader.read { db in
            try DBPendingPhotoUpload.fetchOne(db, key: "task-123")
        }

        #expect(fetched == nil)
    }

    @Test("Can fetch all pending uploads by state")
    func testFetchByState() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

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
            try makeDBConversation(id: "conv-1").insert(db)
            try uploading.insert(db)
            try failed.insert(db)
            try completed.insert(db)
        }

        let failedUploads = try await dbManager.dbReader.read { db in
            try DBPendingPhotoUpload
                .filter(DBPendingPhotoUpload.Columns.state == PendingUploadState.failed.rawValue)
                .fetchAll(db)
        }

        #expect(failedUploads.count == 1)
        #expect(failedUploads.first?.id == "task-2")
    }

    private func makeDBConversation(id: String) -> DBConversation {
        DBConversation(
            id: id,
            inboxId: "test-inbox",
            clientId: "test-client",
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
            includeImageInPublicPreview: false,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false
        )
    }
}
