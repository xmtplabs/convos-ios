import Foundation
import GRDB

enum InboxWriterError: Error, LocalizedError {
    case clientIdMismatch(inboxId: String, existingClientId: String, newClientId: String)

    var errorDescription: String? {
        switch self {
        case let .clientIdMismatch(inboxId, existingClientId, newClientId):
            return """
            INVARIANT VIOLATION: Attempted to save inbox with mismatched clientId.
            InboxId: \(inboxId)
            Existing clientId: \(existingClientId)
            New clientId: \(newClientId)

            This indicates data corruption or a bug in the inbox management flow.
            For a given inboxId, the clientId should never change.
            """
        }
    }
}

/// Writes inbox data to the database
struct InboxWriter {
    private let dbWriter: any DatabaseWriter

    init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    @discardableResult
    func save(inboxId: String, clientId: String, isVault: Bool = false) async throws -> DBInbox {
        try await dbWriter.write { db in
            // Check if inbox already exists
            if let existingInbox = try DBInbox.fetchOne(db, id: inboxId) {
                // INVARIANT: For a given inboxId, the clientId must never change
                // If they don't match, this is a data corruption bug that must be caught
                if existingInbox.clientId != clientId {
                    Log.error("""
                        ClientId mismatch detected!
                        InboxId: \(inboxId)
                        Existing clientId: \(existingInbox.clientId)
                        Attempted clientId: \(clientId)
                        """)
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
                createdAt: Date(),
                isVault: isVault
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
