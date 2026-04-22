import Foundation
import GRDB

final class SharedDatabaseMigrator: Sendable {
    static let shared: SharedDatabaseMigrator = SharedDatabaseMigrator()

    private init() {}

    func migrate(database: any DatabaseWriter) throws {
        let migrator = createMigrator()
        try migrator.migrate(database)
    }
}

extension SharedDatabaseMigrator {
    private func createMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

#if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
#endif

        // Single-inbox baseline. The refactor ships without a data-migration
        // path (see docs/plans/single-inbox-identity-refactor.md) and writes
        // to a new database filename (`convos-single-inbox.sqlite`), so any
        // install that reaches this migrator is either brand new or a
        // post-`LegacyDataWipe` upgrade — either way, starting at a single
        // baseline is correct. Historical v1/v2 migrations from earlier
        // commits on this branch were collapsed into this baseline; no
        // on-disk v0 database in the single-inbox file path exists.
        migrator.registerMigration("v1-single-inbox") { db in
            try SharedDatabaseMigrator.createSingleInboxSchema(db)
        }

        migrator.registerMigration("v2-inactive-conversations") { db in
            try SharedDatabaseMigrator.addInactiveConversationsColumn(db)
        }

        return migrator
    }

    // swiftlint:disable:next function_body_length
    private static func createSingleInboxSchema(_ db: Database) throws {
        // Singleton inbox table. The refactor allows only one inbox per user;
        // writer-layer enforcement lives in `SessionManager`/`InboxWriter`.
        try db.create(table: "inbox") { t in
            t.column("inboxId", .text)
                .notNull()
                .primaryKey()
            t.column("clientId", .text)
                .notNull()
                .unique()
            t.column("createdAt", .datetime)
                .notNull()
        }

        try db.create(table: "member") { t in
            t.column("inboxId", .text)
                .unique()
                .notNull()
                .primaryKey()
        }

        try db.create(table: "conversation") { t in
            t.column("id", .text)
                .notNull()
                .primaryKey()
            t.column("clientConversationId", .text)
                .notNull()
                .unique(onConflict: .replace)
            t.column("inviteTag", .text)
                .notNull()
                .unique()
            t.column("creatorId", .text)
                .notNull()
            t.column("kind", .text).notNull()
            t.column("consent", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("name", .text)
            t.column("description", .text)
            t.column("imageURLString", .text)
            t.column("publicImageURLString", .text)
            t.column("includeInfoInPublicPreview", .boolean).defaults(to: false)
            t.column("expiresAt", .datetime)
            t.column("debugInfo", .jsonText)
            t.column("isLocked", .boolean).notNull().defaults(to: false)
            t.column("imageSalt", .blob)
            t.column("imageNonce", .blob)
            t.column("imageEncryptionKey", .blob)
            t.column("imageLastRenewed", .datetime)
            t.column("isUnused", .boolean).notNull().defaults(to: false)
            t.column("hasHadVerifiedAssistant", .boolean).notNull().defaults(to: false)
            t.column("conversationEmoji", .text)
        }

        try db.create(table: "memberProfile") { t in
            t.column("conversationId", .text)
                .notNull()
                .references("conversation", onDelete: .cascade)
            t.column("inboxId", .text)
                .notNull()
                .references("member", onDelete: .cascade)
            t.column("name", .text)
            t.column("avatar", .text)
            t.column("avatarSalt", .blob)
            t.column("avatarNonce", .blob)
            t.column("avatarKey", .blob)
            t.column("avatarLastRenewed", .datetime)
            t.column("memberKind", .text)
            t.column("metadata", .jsonText)
            t.primaryKey(["conversationId", "inboxId"])
        }

        try db.create(table: "conversation_members") { t in
            t.column("conversationId", .text)
                .notNull()
                .references("conversation", onDelete: .cascade)
            t.column("inboxId", .text)
                .notNull()
                .references("member", onDelete: .cascade)
            t.column("role", .text).notNull()
            t.column("consent", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("invitedByInboxId", .text)
            t.primaryKey(["conversationId", "inboxId"])
        }

        try db.create(table: "invite") { t in
            t.column("urlSlug", .text)
                .notNull()
                .primaryKey()
            t.column("creatorInboxId", .text)
                .notNull()
            t.column("conversationId", .text)
                .notNull()
            t.column("expiresAt", .datetime)
            t.column("expiresAfterUse", .boolean)
                .defaults(to: false)

            t.foreignKey(
                ["creatorInboxId", "conversationId"],
                references: "conversation_members",
                columns: ["inboxId", "conversationId"],
                onDelete: .cascade
            )

            t.uniqueKey(["creatorInboxId", "conversationId"], onConflict: .replace)
        }

        try db.create(table: "conversationLocalState") { t in
            t.column("conversationId", .text)
                .notNull()
                .unique()
                .primaryKey()
                .references("conversation", onDelete: .cascade)
            t.column("isPinned", .boolean).notNull().defaults(to: false)
            t.column("isUnread", .boolean).notNull().defaults(to: false)
            t.column("isUnreadUpdatedAt", .datetime)
                .notNull()
                .defaults(to: Date.distantPast)
            t.column("isMuted", .boolean).notNull().defaults(to: false)
            t.column("pinnedOrder", .integer)
        }

        try db.create(table: "message") { t in
            t.column("id", .text)
                .notNull()
                .primaryKey()
                .unique(onConflict: .replace)
            t.column("clientMessageId", .text)
                .notNull()
                .unique(onConflict: .replace)
            t.column("conversationId", .text)
                .notNull()
                .references("conversation", onDelete: .cascade)
            t.column("senderId", .text)
                .notNull()
                .references("member", onDelete: .none)
            t.column("date", .datetime).notNull()
            t.column("dateNs", .integer).notNull()
            t.column("status", .text).notNull()
            t.column("messageType", .text).notNull()
            t.column("contentType", .text).notNull()
            t.column("text", .text)
            t.column("emoji", .text)
            t.column("sourceMessageId", .text)
            t.column("attachmentUrls", .text)
            t.column("update", .jsonText)
            t.column("invite", .jsonText)
            t.column("sortId", .integer)
            t.column("linkPreview", .jsonText)
        }

        try db.create(table: "photoPreferences") { t in
            t.column("conversationId", .text)
                .notNull()
                .primaryKey()
                .references("conversation", onDelete: .cascade)
            t.column("autoReveal", .boolean)
                .notNull()
                .defaults(to: false)
            t.column("hasRevealedFirst", .boolean)
                .notNull()
                .defaults(to: false)
            t.column("updatedAt", .datetime)
                .notNull()
            t.column("sendReadReceipts", .boolean)
        }

        try db.create(table: "attachmentLocalState") { t in
            t.column("attachmentKey", .text)
                .notNull()
                .primaryKey()
            t.column("conversationId", .text)
                .notNull()
                .references("conversation", onDelete: .cascade)
            t.column("isRevealed", .boolean)
                .notNull()
                .defaults(to: false)
            t.column("revealedAt", .datetime)
            t.column("width", .integer)
            t.column("height", .integer)
            t.column("isHiddenByOwner", .boolean).notNull().defaults(to: false)
            t.column("mimeType", .text)
            t.column("waveformLevels", .text)
            t.column("duration", .double)
        }

        try db.create(table: "pendingPhotoUpload") { t in
            t.column("id", .text).primaryKey()
            t.column("clientMessageId", .text).notNull()
            t.column("conversationId", .text)
                .notNull()
                .references("conversation", onDelete: .cascade)
            t.column("localCacheURL", .text).notNull()
            t.column("state", .text).notNull()
            t.column("errorMessage", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }

        try db.create(table: "voiceMemoTranscript") { t in
            t.column("messageId", .text).notNull().primaryKey()
            t.column("conversationId", .text).notNull().references("conversation", onDelete: .cascade)
            t.column("attachmentKey", .text).notNull()
            t.column("status", .text).notNull()
            t.column("text", .text)
            t.column("errorDescription", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }

        try db.create(table: "conversation_read_receipts") { t in
            t.column("conversationId", .text).notNull()
                .references("conversation", onDelete: .cascade)
            t.column("inboxId", .text).notNull()
                .references("member", onDelete: .cascade)
            t.column("readAtNs", .integer).notNull()
            t.primaryKey(["conversationId", "inboxId"])
        }

        // Indexes
        try db.create(
            index: "attachmentLocalState_conversationId",
            on: "attachmentLocalState",
            columns: ["conversationId"]
        )
        try db.create(
            index: "pendingPhotoUpload_state",
            on: "pendingPhotoUpload",
            columns: ["state"]
        )
        try db.create(
            index: "pendingPhotoUpload_clientMessageId",
            on: "pendingPhotoUpload",
            columns: ["clientMessageId"]
        )
        try db.create(
            index: "pendingPhotoUpload_conversationId",
            on: "pendingPhotoUpload",
            columns: ["conversationId"]
        )
        try db.create(
            index: "message_sortId",
            on: "message",
            columns: ["conversationId", "sortId"]
        )
        try db.create(
            index: "message_on_conversationId_dateNs",
            on: "message",
            columns: ["conversationId", "dateNs"]
        )
        try db.create(
            index: "message_on_sourceMessageId_messageType",
            on: "message",
            columns: ["sourceMessageId", "messageType"]
        )
        try db.create(
            index: "message_on_conversationId_contentType_dateNs",
            on: "message",
            columns: ["conversationId", "contentType", "dateNs"]
        )
        try db.create(
            index: "message_on_sourceMessageId_senderId_emoji_messageType",
            on: "message",
            columns: ["sourceMessageId", "senderId", "emoji", "messageType"]
        )
        try db.create(
            index: "conversation_members_on_inboxId_conversationId",
            on: "conversation_members",
            columns: ["inboxId", "conversationId"]
        )
        try db.create(
            index: "memberProfile_on_conversationId_inboxId",
            on: "memberProfile",
            columns: ["conversationId", "inboxId"]
        )
        try db.create(
            index: "message_assistantJoinRequest_conversationId",
            on: "message",
            columns: ["conversationId", "contentType", "dateNs"],
            condition: Column("contentType") == MessageContentType.assistantJoinRequest.rawValue
        )
        try db.create(
            index: "voiceMemoTranscript_conversationId",
            on: "voiceMemoTranscript",
            columns: ["conversationId"]
        )
        try db.create(
            index: "voiceMemoTranscript_attachmentKey",
            on: "voiceMemoTranscript",
            columns: ["attachmentKey"]
        )
        try db.create(
            index: "idx_read_receipts_conversation",
            on: "conversation_read_receipts",
            columns: ["conversationId"]
        )
    }

    /// Conversations restored from an iCloud backup come back inactive because
    /// the restored installation has to be re-admitted to each MLS group by a
    /// peer before it can participate. The `isActive` flag drives the post-
    /// restore UI (muted composer, "History restored" banner) and is flipped
    /// back to true by `StreamProcessor` when a real reactivation signal
    /// arrives. Default is true so existing rows are unaffected.
    private static func addInactiveConversationsColumn(_ db: Database) throws {
        try db.alter(table: "conversationLocalState") { t in
            t.add(column: "isActive", .boolean).notNull().defaults(to: true)
        }
    }
}
