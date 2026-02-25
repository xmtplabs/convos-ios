import Foundation
import GRDB

public protocol PendingPhotoUploadWriterProtocol: Sendable {
    func create(_ upload: DBPendingPhotoUpload) async throws
    func updateState(taskId: String, state: PendingUploadState, errorMessage: String?) async throws
    func delete(taskId: String) async throws
    func fetch(taskId: String) async throws -> DBPendingPhotoUpload?
    func fetchPendingRetries() async throws -> [DBPendingPhotoUpload]
    func fetchUploadsNeedingXMTPSend() async throws -> [DBPendingPhotoUpload]
}

public final class PendingPhotoUploadWriter: PendingPhotoUploadWriterProtocol, Sendable {
    private let databaseWriter: any DatabaseWriter

    public init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func create(_ upload: DBPendingPhotoUpload) async throws {
        try await databaseWriter.write { db in
            try upload.insert(db)
        }
    }

    public func updateState(
        taskId: String,
        state: PendingUploadState,
        errorMessage: String? = nil
    ) async throws {
        try await databaseWriter.write { db in
            try DBPendingPhotoUpload
                .filter(key: taskId)
                .updateAll(
                    db,
                    DBPendingPhotoUpload.Columns.state.set(to: state),
                    DBPendingPhotoUpload.Columns.errorMessage.set(to: errorMessage),
                    DBPendingPhotoUpload.Columns.updatedAt.set(to: Date())
                )
        }
    }

    public func delete(taskId: String) async throws {
        _ = try await databaseWriter.write { db in
            try DBPendingPhotoUpload.deleteOne(db, key: taskId)
        }
    }

    public func fetch(taskId: String) async throws -> DBPendingPhotoUpload? {
        try await databaseWriter.read { db in
            try DBPendingPhotoUpload.fetchOne(db, key: taskId)
        }
    }

    public func fetchPendingRetries() async throws -> [DBPendingPhotoUpload] {
        try await databaseWriter.read { db in
            try DBPendingPhotoUpload
                .filter(DBPendingPhotoUpload.Columns.state == PendingUploadState.failed.rawValue)
                .fetchAll(db)
        }
    }

    public func fetchUploadsNeedingXMTPSend() async throws -> [DBPendingPhotoUpload] {
        try await databaseWriter.read { db in
            try DBPendingPhotoUpload
                .filter(DBPendingPhotoUpload.Columns.state == PendingUploadState.sending.rawValue)
                .fetchAll(db)
        }
    }
}
