import Foundation
import GRDB

enum InboxWriterError: Error, LocalizedError {
    case clientIdMismatch(inboxId: String, existingClientId: String, newClientId: String)

    var errorDescription: String? {
        switch self {
        case let .clientIdMismatch(inboxId, existingClientId, newClientId):
            return """
            Attempted to save inbox with mismatched clientId. \
            inboxId=\(inboxId) existingClientId=\(existingClientId) newClientId=\(newClientId). \
            For a given inboxId, the clientId is expected to be stable — a mismatch indicates \
            data corruption or a bug in the inbox management flow.
            """
        }
    }
}

/// Writes inbox data to the database.
struct InboxWriter {
    private let dbWriter: any DatabaseWriter

    init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    @discardableResult
    func save(inboxId: String, clientId: String) async throws -> DBInbox {
        try await dbWriter.write { db in
            if let existingInbox = try DBInbox.fetchOne(db, id: inboxId) {
                // For a given inboxId, the clientId is expected to be stable; a
                // mismatch here means either a data corruption bug or a stale DB
                // row from a previous identity that wasn't cleaned up.
                if existingInbox.clientId != clientId {
                    Log.error("ClientId mismatch: inboxId=\(inboxId) existingClientId=\(existingInbox.clientId) attemptedClientId=\(clientId)")
                    throw InboxWriterError.clientIdMismatch(
                        inboxId: inboxId,
                        existingClientId: existingInbox.clientId,
                        newClientId: clientId
                    )
                }
                return existingInbox
            }

            let inbox = DBInbox(
                inboxId: inboxId,
                clientId: clientId,
                createdAt: Date()
            )
            try inbox.insert(db)
            return inbox
        }
    }

    func delete(inboxId: String) async throws {
        try await dbWriter.write { db in
            _ = try DBInbox.deleteOne(db, id: inboxId)
        }
    }

    func delete(clientId: String) async throws {
        _ = try await dbWriter.write { db in
            try DBInbox
                .filter(DBInbox.Columns.clientId == clientId)
                .deleteAll(db)
        }
    }

    func deleteAll() async throws {
        _ = try await dbWriter.write { db in
            try DBInbox.deleteAll(db)
        }
    }
}
