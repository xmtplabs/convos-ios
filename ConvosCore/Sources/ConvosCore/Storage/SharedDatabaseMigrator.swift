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
    // swiftlint:disable:next function_body_length
    private func createMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

#if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
#endif

        migrator.registerMigration("createSchema") { db in
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
                t.column("inboxId", .text)
                    .notNull()
                t.column("clientId", .text)
                    .notNull()
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
                t.column("expiresAt", .datetime)
                t.column("debugInfo", .jsonText)
                t.uniqueKey(["id", "inboxId", "clientId"])
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

                // Foreign key to the conversation member who created this invite
                t.foreignKey(
                    ["creatorInboxId", "conversationId"],
                    references: "conversation_members",
                    columns: ["inboxId", "conversationId"],
                    onDelete: .cascade
                )

                // Unique constraint to prevent duplicate invites per member per conversation
                t.uniqueKey(["creatorInboxId", "conversationId"], onConflict: .replace)
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
                t.primaryKey(["conversationId", "inboxId"])
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
            }
        }

        migrator.registerMigration("addInviteToMessage") { db in
            try db.alter(table: "message") { t in
                t.add(column: "invite", .jsonText)
            }
        }

        migrator.registerMigration("addPinnedOrderToConversationLocalState") { db in
            try db.alter(table: "conversationLocalState") { t in
                t.add(column: "pinnedOrder", .integer)
            }
        }

        migrator.registerMigration("addPublicImagePreview") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "publicImageURLString", .text)
                t.add(column: "includeImageInPublicPreview", .boolean).defaults(to: false)
            }
        }

        migrator.registerMigration("renameIncludeImageToIncludeInfo") { db in
            try db.alter(table: "conversation") { t in
                t.rename(column: "includeImageInPublicPreview", to: "includeInfoInPublicPreview")
            }
        }

        migrator.registerMigration("addEncryptedAvatarColumns") { db in
            try db.alter(table: "memberProfile") { t in
                t.add(column: "avatarSalt", .blob)
                t.add(column: "avatarNonce", .blob)
            }
        }

        migrator.registerMigration("addIsLockedToConversation") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "isLocked", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("addAvatarKeyToMemberProfile") { db in
            try db.alter(table: "memberProfile") { t in
                t.add(column: "avatarKey", .blob)
            }
        }

        migrator.registerMigration("addGroupImageEncryptionToConversation") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "imageSalt", .blob)
                t.add(column: "imageNonce", .blob)
                t.add(column: "imageEncryptionKey", .blob)
            }
        }

        migrator.registerMigration("addAssetRenewalColumns") { db in
            try db.alter(table: "memberProfile") { t in
                t.add(column: "avatarLastRenewed", .datetime)
            }
            try db.alter(table: "conversation") { t in
                t.add(column: "imageLastRenewed", .datetime)
            }
        }

        migrator.registerMigration("deduplicateReactions") { db in
            try db.execute(sql: """
                DELETE FROM message
                WHERE messageType = 'reaction'
                AND sourceMessageId IS NOT NULL
                AND rowid NOT IN (
                    SELECT MIN(rowid)
                    FROM message
                    WHERE messageType = 'reaction'
                    AND sourceMessageId IS NOT NULL
                    GROUP BY sourceMessageId, senderId, emoji
                )
                """)
        }

        migrator.registerMigration("createPhotoPreferences") { db in
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
            }
        }

        migrator.registerMigration("createAttachmentLocalState") { db in
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
            }

            try db.create(index: "attachmentLocalState_conversationId", on: "attachmentLocalState", columns: ["conversationId"])
        }

        migrator.registerMigration("createPendingPhotoUpload") { db in
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

            try db.create(index: "pendingPhotoUpload_state", on: "pendingPhotoUpload", columns: ["state"])
            try db.create(index: "pendingPhotoUpload_clientMessageId", on: "pendingPhotoUpload", columns: ["clientMessageId"])
            try db.create(index: "pendingPhotoUpload_conversationId", on: "pendingPhotoUpload", columns: ["conversationId"])
        }

        migrator.registerMigration("addDimensionsToAttachmentLocalState") { db in
            try db.alter(table: "attachmentLocalState") { t in
                t.add(column: "width", .integer)
                t.add(column: "height", .integer)
            }
        }

        migrator.registerMigration("addIsHiddenByOwnerToAttachmentLocalState") { db in
            try db.alter(table: "attachmentLocalState") { t in
                t.add(column: "isHiddenByOwner", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("addSortIdToMessage") { db in
            try db.alter(table: "message") { t in
                t.add(column: "sortId", .integer)
            }

            try db.execute(sql: """
                UPDATE message SET sortId = (
                    SELECT COUNT(*) FROM message m2
                    WHERE m2.conversationId = message.conversationId
                    AND m2.dateNs <= message.dateNs
                    AND m2.id <= message.id
                )
            """)

            try db.create(index: "message_sortId", on: "message", columns: ["conversationId", "sortId"])
        }

        migrator.registerMigration("addPerformanceIndexes") { db in
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
        }

        migrator.registerMigration("addIsUnusedToConversation") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "isUnused", .boolean).notNull().defaults(to: false)
            }
        }

        return migrator
    }
}
