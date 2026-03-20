import Foundation
import GRDB

enum InboxWriterError: Error, LocalizedError {
    case clientIdMismatch(inboxId: String, existingClientId: String, newClientId: String)
    case duplicateVault(existingInboxId: String)

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
        case let .duplicateVault(existingInboxId):
            return "A Vault inbox already exists with inboxId: \(existingInboxId)"
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
    func save(
        inboxId: String,
        clientId: String,
        installationId: String? = nil,
        isVault: Bool = false
    ) async throws -> DBInbox {
        try await dbWriter.write { db in
            if isVault {
                let existingVault = try DBInbox
                    .filter(DBInbox.Columns.isVault == true)
                    .fetchOne(db)
                if let existingVault, existingVault.inboxId != inboxId {
                    throw InboxWriterError.duplicateVault(existingInboxId: existingVault.inboxId)
                }
            }

            if let existingInbox = try DBInbox.fetchOne(db, id: inboxId) {
                var currentInbox = existingInbox

                if existingInbox.clientId != clientId {
                    if isVault {
                        Log.info("Vault clientId changed (new installation): \(existingInbox.clientId) → \(clientId)")
                        try db.execute(
                            sql: "UPDATE inbox SET clientId = ? WHERE inboxId = ?",
                            arguments: [clientId, inboxId]
                        )
                        currentInbox = try DBInbox.fetchOne(db, id: inboxId) ?? existingInbox
                    } else {
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
                }

                guard let installationId else {
                    return currentInbox
                }

                guard currentInbox.installationId != installationId else {
                    return currentInbox
                }

                var updatedInbox = currentInbox
                updatedInbox.installationId = installationId
                try updatedInbox.update(db)
                return updatedInbox
            }

            let inbox = DBInbox(
                inboxId: inboxId,
                clientId: clientId,
                createdAt: Date(),
                isVault: isVault,
                installationId: installationId
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

    func markStale(inboxId: String, _ isStale: Bool = true) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE inbox SET isStale = ? WHERE inboxId = ?",
                arguments: [isStale, inboxId]
            )
        }
    }

    func deleteAll() async throws {
        try await dbWriter.write { db in
            let tables = [
                "message",
                "attachmentLocalState",
                "conversationLocalState",
                "invite",
                "conversation_members",
                "memberProfile",
                "photoPreferences",
                "pendingPhotoUpload",
                "conversation",
                "member",
                "vaultDevice",
                "inbox",
            ]
            for table in tables {
                do {
                    try db.execute(sql: "DELETE FROM \(table)")
                } catch {
                    Log.error("deleteAll: failed to delete from \(table): \(error)")
                    throw error
                }
            }
        }
    }
}
