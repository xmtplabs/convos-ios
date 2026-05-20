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

        migrator.registerMigration("createMyProfile") { db in
            try db.create(table: "myProfile") { t in
                t.column("inboxId", .text).notNull().primaryKey()
                t.column("name", .text)
                t.column("imageData", .blob)
                t.column("metadata", .jsonText)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("myProfileImageAssetIdentifier") { db in
            try db.alter(table: "myProfile") { t in
                t.add(column: "imageAssetIdentifier", .text)
            }
        }

        // Vestigial: superseded by `profileImageContentDigest`. Kept registered so DBs that
        // already applied it don't trip GRDB's migration-checksum check; the column itself is
        // unused going forward.
        migrator.registerMigration("memberProfileImageSourceAssetIdentifier") { db in
            try db.alter(table: "memberProfile") { t in
                t.add(column: "imageSourceAssetIdentifier", .text)
            }
        }

        migrator.registerMigration("profileImageContentDigest") { db in
            try db.alter(table: "myProfile") { t in
                t.add(column: "imageContentDigest", .text)
            }
            try db.alter(table: "memberProfile") { t in
                t.add(column: "imageSourceContentDigest", .text)
            }
        }

        migrator.registerMigration("createConnections", migrate: Self.createConnections)

        migrator.registerMigration("createCapabilityResolution") { db in
            // Per-(subject, conversation, capability) routing decision. Set cardinality is
            // enforced in CapabilityResolutionValidator, not the schema, because the
            // schema needs to support both single and multi-provider rows uniformly.
            try db.create(table: "capabilityResolution") { t in
                t.column("subject", .text).notNull()
                t.column("conversationId", .text).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("capability", .text).notNull()
                t.column("providerIds", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["subject", "conversationId", "capability"])
            }

            try db.create(
                index: "capabilityResolution_conversationId",
                on: "capabilityResolution",
                columns: ["conversationId"]
            )
        }

        migrator.registerMigration("createConnectionEnablement") { db in
            try db.create(table: "connectionEnablement") { t in
                t.column("kind", .text).notNull()
                t.column("capability", .text).notNull()
                t.column("conversationId", .text).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["kind", "capability", "conversationId"])
            }

            try db.create(
                index: "connectionEnablement_conversationId",
                on: "connectionEnablement",
                columns: ["conversationId"]
            )

            try db.create(table: "connectionAlwaysConfirm") { t in
                t.column("kind", .text).notNull()
                t.column("conversationId", .text).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("alwaysConfirm", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["kind", "conversationId"])
            }
        }

        migrator.registerMigration("createHealthBackgroundSubscriptions") { db in
            // Per-(conversation, agent, HealthSampleType) subscription rows. The
            // observer-query anchor is an NSKeyed-archived `HKQueryAnchor` produced by
            // anchored object queries; nil until the first delta is delivered for the
            // subscription. See docs/plans/healthkit-background-subscriptions.md.
            try db.create(table: "healthBackgroundSubscription") { t in
                t.column("conversationId", .text).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("agentInboxId", .text).notNull()
                t.column("typeIdentifier", .text).notNull()
                t.column("frequency", .text).notNull()
                t.column("historyDays", .integer).notNull()
                t.column("anchor", .blob)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["conversationId", "agentInboxId", "typeIdentifier"])
            }

            try db.create(
                index: "healthBackgroundSubscription_typeIdentifier",
                on: "healthBackgroundSubscription",
                columns: ["typeIdentifier"]
            )
        }

        migrator.registerMigration("scopeGrantsToAgentInboxId", migrate: Self.scopeGrantsToAgentInboxId)

        Self.registerContactsMVPMigrations(on: &migrator)

        migrator.registerMigration("createAgentBuilderSummary", migrate: Self.createAgentBuilderSummary)

        migrator.registerMigration("addAgentBuilderSummaryBundledMessageIds", migrate: Self.addAgentBuilderSummaryBundledMessageIds)

        migrator.registerMigration("createThinkingSession", migrate: Self.createThinkingSession)

        migrator.registerMigration("replaceThinkingSessionWithThinkingMoment", migrate: Self.replaceThinkingSessionWithThinkingMoment)

        migrator.registerMigration("renameConversationHasHadVerifiedAssistantToAgent", migrate: Self.renameConversationHasHadVerifiedAssistantToAgent)
        Self.registerAgentTemplateContactMigrations(on: &migrator)

        migrator.registerMigration("addAgentBuilderSummaryCloudConnectionIds", migrate: Self.addAgentBuilderSummaryCloudConnectionIds)

        migrator.registerMigration("addAgentBuilderSummaryConnectionsAppliedAt", migrate: Self.addAgentBuilderSummaryConnectionsAppliedAt)

        return migrator
    }

    private static func createConnections(_ db: Database) throws {
        try db.create(table: "connection") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("serviceId", .text).notNull()
            t.column("serviceName", .text).notNull()
            t.column("provider", .text).notNull()
            t.column("composioEntityId", .text).notNull()
            t.column("composioConnectionId", .text).notNull()
            t.column("status", .text).notNull()
            t.column("connectedAt", .datetime).notNull()
        }

        try db.create(table: "connectionGrant") { t in
            t.column("connectionId", .text).notNull()
                .references("connection", onDelete: .cascade)
            t.column("conversationId", .text).notNull()
                .references("conversation", onDelete: .cascade)
            t.column("serviceId", .text).notNull()
            t.column("grantedAt", .datetime).notNull()
            t.primaryKey(["connectionId", "conversationId"])
        }

        try db.create(
            index: "connectionGrant_conversationId",
            on: "connectionGrant",
            columns: ["conversationId"]
        )
    }

    /// Snapshot of an Agent Builder draft captured at the moment the user
    /// tapped Make. Replaces the user's prompt sends + any pre-Make agent
    /// chatter with a single summary card at the top of the post-commit
    /// messages list. One row per conversation; cascade-deleted when the
    /// conversation is.
    private static func createAgentBuilderSummary(_ db: Database) throws {
        try db.create(table: "agentBuilderSummary") { t in
            t.column("conversationId", .text).notNull().primaryKey()
                .references("conversation", onDelete: .cascade)
            t.column("summaryId", .text).notNull()
            t.column("prompt", .text).notNull()
            t.column("attachmentsJSON", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("cutoffDate", .datetime).notNull()
        }
    }

    /// JSON-encoded `[String]` of the `clientMessageId`s that the Agent
    /// Builder issued on the user's behalf at commit. Replaces the
    /// timestamp-padded filter that used to swallow user-side bundle sends —
    /// uploads could stretch the multi-remote `sentAt` past the pad, leaking
    /// a bare bundle bubble underneath the summary card. Defaults to `"[]"`
    /// for rows written before this column existed; the hydrate path treats
    /// an empty / malformed JSON the same as "no ids tracked".
    private static func addAgentBuilderSummaryBundledMessageIds(_ db: Database) throws {
        try db.alter(table: "agentBuilderSummary") { t in
            t.add(column: "bundledMessageIdsJSON", .text).notNull().defaults(to: "[]")
        }
    }

    /// JSON-encoded `[String: String]` mapping AgentBuilderConnection
    /// rawValue → captured CloudConnection.id. Drives the post-Make grant
    /// replayer: a force-quit between Make and agent-join no longer loses
    /// the user's selected cloud connections — the replayer reads the
    /// summary on next launch and fires the grants once the agent appears.
    /// Defaults to `"{}"` on older summaries.
    private static func addAgentBuilderSummaryCloudConnectionIds(_ db: Database) throws {
        try db.alter(table: "agentBuilderSummary") { t in
            t.add(column: "cloudConnectionIdsJSON", .text).notNull().defaults(to: "{}")
        }
    }

    /// Timestamp set the first time the `AgentBuilderConnectionGrantReplayer`
    /// finishes a successful pass over a summary's connections. Once set,
    /// the replayer skips the row so a manual revoke from the chat UI
    /// doesn't get silently undone by the next launch's replay scan. Nullable
    /// — `nil` for summaries written before this column existed (those are
    /// still safe to replay because the original commit's in-memory poll
    /// would have either landed before the upgrade or been lost to app
    /// death; the replayer's grant-store idempotency check keeps duplicate
    /// firings from doing damage even in the worst case).
    private static func addAgentBuilderSummaryConnectionsAppliedAt(_ db: Database) throws {
        try db.alter(table: "agentBuilderSummary") { t in
            t.add(column: "connectionsAppliedAt", .datetime)
        }
    }

    /// Rename `conversation.hasHadVerifiedAssistant` -> `hasHadVerifiedAgent`
    /// for naming consistency with the Assistant -> Agent rename. The
    /// original column was introduced on the conversation table create
    /// migration that has already shipped to dev, so this rename has to
    /// happen via a new migration rather than editing the original column
    /// definition in place.
    private static func renameConversationHasHadVerifiedAssistantToAgent(_ db: Database) throws {
        try db.alter(table: "conversation") { t in
            t.rename(column: "hasHadVerifiedAssistant", to: "hasHadVerifiedAgent")
        }
    }

    /// One row per `convos.org/thinking:1.0` session received from a remote
    /// agent. `endedAtNs == NULL` marks an in-flight session; `resultMessageId`
    /// is populated on `stop` when the agent linked a reply message. Cascade
    /// with the conversation. A partial unique index keeps at most one active
    /// session per (conversation, sender, targetMessage) — closed history
    /// rows for the same triple are allowed.
    private static func createThinkingSession(_ db: Database) throws {
        try db.create(table: "thinkingSession") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("conversationId", .text).notNull()
                .references("conversation", onDelete: .cascade)
            t.column("senderInboxId", .text).notNull()
            t.column("targetMessageId", .text).notNull()
            t.column("content", .text).notNull()
            t.column("startedAtNs", .integer).notNull()
            t.column("endedAtNs", .integer)
            t.column("resultMessageId", .text)
        }
        try db.execute(sql: """
            CREATE UNIQUE INDEX thinkingSession_activeKey
            ON thinkingSession(conversationId, senderInboxId, targetMessageId)
            WHERE endedAtNs IS NULL
        """)
        try db.create(
            index: "thinkingSession_conversationId_startedAtNs",
            on: "thinkingSession",
            columns: ["conversationId", "startedAtNs"]
        )
    }

    /// Replace `thinkingSession` (one row per session, idempotent-refresh
    /// semantics) with `thinkingMoment` (one row per codec event). The
    /// session aggregate is computed at read time by the repository. Each
    /// agent `start` now becomes its own moment so the detail view can
    /// render the full history; `id` is the XMTP message id so re-delivery
    /// of the same event is a PK no-op. Drop+recreate is acceptable —
    /// thinking is still on a feature branch with no production data.
    private static func replaceThinkingSessionWithThinkingMoment(_ db: Database) throws {
        try db.drop(table: "thinkingSession")
        try db.create(table: "thinkingMoment") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("conversationId", .text).notNull()
                .references("conversation", onDelete: .cascade)
            t.column("senderInboxId", .text).notNull()
            t.column("targetMessageId", .text).notNull()
            t.column("state", .text).notNull()
            t.column("content", .text).notNull()
            t.column("sentAtNs", .integer).notNull()
            t.column("resultMessageId", .text)
        }
        try db.create(
            index: "thinkingMoment_sessionKey",
            on: "thinkingMoment",
            columns: ["conversationId", "senderInboxId", "targetMessageId", "sentAtNs"]
        )
    }

    private static func registerContactsMVPMigrations(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("createContactTable") { db in
            try SharedDatabaseMigrator.createContactSchema(db)
        }

        migrator.registerMigration("addContactBlockedAt") { db in
            try db.alter(table: "contact") { t in
                t.add(column: "blockedAt", .datetime)
            }
        }

        migrator.registerMigration("addConversationQuarantineFields") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "quarantinedAt", .datetime)
                t.add(column: "quarantineReleasedAt", .datetime)
            }
        }

        migrator.registerMigration("addContactAgentVerification") { db in
            try db.alter(table: "contact") { t in
                t.add(column: "agentVerification", .jsonText)
            }
        }

        // Avatar encryption fields mirror `memberProfile` so the contact card
        // and contact list can render the same encrypted image without
        // re-fetching the per-conversation profile. Nullable: a contact
        // observed only as a name-only ProfileUpdate has no image yet.
        migrator.registerMigration("addContactAvatarEncryptionFields") { db in
            try db.alter(table: "contact") { t in
                t.add(column: "avatarSalt", .blob)
                t.add(column: "avatarNonce", .blob)
                t.add(column: "avatarKey", .blob)
            }
        }

        // Per-conversation local flag: suppress the invite QR header for
        // convos started from the contacts picker. The QR is meant as
        // the empty-state CTA; a picker-seeded convo already has members
        // and shouldn't lead with it. Stored locally because it's a UI
        // preference, not consensus state.
        //
        // The `.notNull().defaults(to: false)` clause lets SQLite back-
        // fill the column for existing rows in `conversationLocalState`
        // with `false`, which matches the legacy behavior (no QR
        // suppression) - so conversations created before this migration
        // continue to render the QR header as they did.
        migrator.registerMigration("addConversationLocalStateHidesInviteCard") { db in
            try db.alter(table: "conversationLocalState") { t in
                t.add(column: "hidesInviteCard", .boolean).notNull().defaults(to: false)
            }
        }

        // Single-row credit_balance cache. The backend remains the source of
        // truth (`GET /v2/accounts/me/credits`); this table just gives us a
        // GRDB-observable read surface so the HOME pill, conversation banner,
        // settings detail, and paywall stay in lockstep via the same
        // observation channel the rest of the app uses. `id` is a fixed
        // sentinel so the table holds at most one row per install.
        migrator.registerMigration("createCreditBalance") { db in
            try db.create(table: "credit_balance") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("balance", .integer).notNull()
                t.column("monthlyGrant", .integer).notNull()
                t.column("monthlyGrantUsed", .integer).notNull()
                t.column("nextRefreshAt", .datetime).notNull()
                t.column("periodLabel", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
    }

    /// Agent Templates Phase 2: the templateId-keyed agent-template contact
    /// table. Separate from the inboxId-keyed `contact` table because a
    /// template instantiated into N conversations produces N distinct agent
    /// inboxIds - the stable identity of the contact is the template.
    /// Registered after the contacts-MVP migrations so the
    /// `addedViaConversationId` foreign key against `conversation` resolves.
    private static func registerAgentTemplateContactMigrations(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("createAgentTemplateContactTable") { db in
            try SharedDatabaseMigrator.createAgentTemplateContactSchema(db)
        }
    }

    /// Tighten capabilityResolution + connectionEnablement + connectionGrant so a grant
    /// is bound to a specific agent's inboxId instead of being conversation-wide. Two
    /// agents in the same conversation now have independent rows; one's grant doesn't
    /// authorize the other. Drop+recreate is acceptable here because no production data
    /// exists for these tables yet (the connections feature is still on a feature branch).
    private static func scopeGrantsToAgentInboxId(_ db: Database) throws {
        try db.drop(table: "capabilityResolution")
        try db.create(table: "capabilityResolution") { t in
            t.column("subject", .text).notNull()
            t.column("conversationId", .text).notNull()
                .references("conversation", onDelete: .cascade)
            t.column("capability", .text).notNull()
            t.column("grantedToInboxId", .text).notNull()
            t.column("providerIds", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.primaryKey(["subject", "conversationId", "capability", "grantedToInboxId"])
        }
        try db.create(
            index: "capabilityResolution_conversationId",
            on: "capabilityResolution",
            columns: ["conversationId"]
        )

        try db.drop(table: "connectionEnablement")
        try db.create(table: "connectionEnablement") { t in
            t.column("kind", .text).notNull()
            t.column("capability", .text).notNull()
            t.column("conversationId", .text).notNull()
                .references("conversation", onDelete: .cascade)
            t.column("grantedToInboxId", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.primaryKey(["kind", "capability", "conversationId", "grantedToInboxId"])
        }
        try db.create(
            index: "connectionEnablement_conversationId",
            on: "connectionEnablement",
            columns: ["conversationId"]
        )

        try db.drop(table: "connectionGrant")
        try db.create(table: "connectionGrant") { t in
            t.column("connectionId", .text).notNull()
                .references("connection", onDelete: .cascade)
            t.column("conversationId", .text).notNull()
                .references("conversation", onDelete: .cascade)
            t.column("serviceId", .text).notNull()
            t.column("grantedToInboxId", .text).notNull()
            t.column("grantedAt", .datetime).notNull()
            t.primaryKey(["connectionId", "conversationId", "grantedToInboxId"])
        }
        try db.create(
            index: "connectionGrant_conversationId",
            on: "connectionGrant",
            columns: ["conversationId"]
        )
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
            // `hidesInviteCard` is added by a later migration so existing
            // installs back-fill correctly; don't list it here or the
            // ALTER below will fail with `duplicate column name` on a
            // fresh database.
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

    /// Contacts table. Stores a denormalized "global default profile" snapshot
    /// keyed by `inboxId`. Profile fields are updated most-recent-wins as new
    /// member-profile data arrives. The `addedViaConversationId` foreign key
    /// uses `setNull` so deleting the source conversation does not delete the
    /// contact — contacts survive the local user leaving every shared group.
    /// `blockedAt` is added by the `addContactBlockedAt` migration registered
    /// alongside this baseline.
    private static func createContactSchema(_ db: Database) throws {
        try db.create(table: "contact") { t in
            t.column("inboxId", .text)
                .notNull()
                .primaryKey()
            t.column("addedAt", .datetime).notNull()
            t.column("addedViaConversationId", .text)
                .references("conversation", onDelete: .setNull)
            t.column("displayName", .text)
            t.column("avatarURL", .text)
            t.column("profileUpdatedAt", .datetime)
        }

        try db.create(
            index: "idx_contact_displayName",
            on: "contact",
            columns: ["displayName"]
        )

        try db.create(table: "conversation_contacts_sync") { t in
            t.column("conversationId", .text)
                .notNull()
                .primaryKey()
                .references("conversation", onDelete: .cascade)
            t.column("contactsSyncedAt", .datetime).notNull()
        }
    }

    /// Agent-template contact table. Keyed by `templateId` (the backend
    /// `AgentTemplate.id`), storing a most-recent-wins snapshot of the
    /// template profile fields observed from encountered instances.
    /// `addedViaConversationId` uses `setNull` so the contact survives its
    /// source conversation, matching the `contact` table. No `blockedAt`
    /// column: agent-template contacts support Remove only (see
    /// docs/plans/agent-templates-phase-2-prd.md).
    private static func createAgentTemplateContactSchema(_ db: Database) throws {
        try db.create(table: "agentTemplateContact") { t in
            t.column("templateId", .text)
                .notNull()
                .primaryKey()
            t.column("addedAt", .datetime).notNull()
            t.column("addedViaConversationId", .text)
                .references("conversation", onDelete: .setNull)
            t.column("displayName", .text)
            t.column("emoji", .text)
            t.column("descriptionText", .text)
            t.column("publishedURL", .text)
            t.column("avatarURL", .text)
            t.column("agentVerification", .jsonText)
            t.column("profileUpdatedAt", .datetime)
        }

        try db.create(
            index: "idx_agentTemplateContact_displayName",
            on: "agentTemplateContact",
            columns: ["displayName"]
        )
    }
}
