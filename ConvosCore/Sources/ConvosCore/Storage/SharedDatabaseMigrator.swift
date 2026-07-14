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

        migrator.registerMigration("addAgentBuilderSummaryCloudConnectionIds", migrate: Self.addAgentBuilderSummaryCloudConnectionIds)

        migrator.registerMigration("addAgentBuilderSummaryConnectionsAppliedAt", migrate: Self.addAgentBuilderSummaryConnectionsAppliedAt)

        migrator.registerMigration("addAgentBuilderSummaryExistingConversation", migrate: Self.addAgentBuilderSummaryExistingConversation)

        migrator.registerMigration("dropConversationQuarantineFields", migrate: Self.dropConversationQuarantineFields)

        migrator.registerMigration("addContactAgentTemplateFields", migrate: Self.addContactAgentTemplateFields)

        migrator.registerMigration("createAgentTemplateCache", migrate: Self.createAgentTemplateCache)

        // Append new migrations below this line; never insert one earlier in the
        // list. In DEBUG builds `eraseDatabaseOnSchemaChange` replays a temporary
        // database up to the last-applied migration and erases the real database
        // when the schemas differ. A migration registered ahead of an
        // already-applied one makes that replay diverge from an upgraded install
        // and wipes its data - and DEBUG covers the Dev and PR TestFlight configs,
        // not just local builds. Appending keeps the replay equal to the on-disk
        // schema, so an upgrade migrates in place.
        Self.registerAgentTemplateContactMigrations(on: &migrator)

        Self.registerBuilderBundleHiddenMessageMigrations(on: &migrator)

        migrator.registerMigration("backfillContactAgentTemplateFieldsFromMemberProfiles",
                                   migrate: Self.backfillContactAgentTemplateFieldsFromMemberProfiles)

        migrator.registerMigration("addAgentTemplateDescriptionAndSlug", migrate: Self.addAgentTemplateDescriptionAndSlug)

        Self.registerRemovedStateMigrations(on: &migrator)
        Self.registerConnectionGrantMigrations(on: &migrator)
        Self.registerJoinAndGenerationMigrations(on: &migrator)
        Self.registerTailMigrations(on: &migrator)
        Self.registerMemberDepartureMigrations(on: &migrator)

        return migrator
    }

    /// Per-conversation catch-up cursor (see DBConversationCatchUpCursor).
    /// Tracks how far the backlog has actually been fetched and applied,
    /// independently of MAX(message.dateNs), so read receipts older than
    /// the newest pushed message are no longer skipped by catch-up.
    private static func registerCatchUpCursorMigrations(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("createConversationCatchUpCursor") { db in
            try db.create(table: "conversation_catchup_cursors") { t in
                t.column("conversationId", .text).notNull().primaryKey()
                    .references("conversation", onDelete: .cascade)
                t.column("caughtUpToNs", .integer).notNull()
            }
        }
    }

    /// Set-once high-water mark: true once a conversation has ever had a
    /// member besides the local inbox. Member rows are deleted on departure
    /// sync, so without this flag a joined-then-left conversation is
    /// indistinguishable from an untouched draft - and the engagement gate
    /// (`ConversationEngagement`) would let implicit cleanup discard it.
    ///
    /// The column defaults to false; the backfill flags conversations that
    /// currently hold a member row for an inbox other than the local one.
    /// Departed-member history cannot be reconstructed on upgrade, so
    /// pre-migration joined-then-left conversations start false - they are
    /// still protected by their messages or metadata in practice. Extracted
    /// as an internal static helper so the migration test can exercise the
    /// real upgrade path without tripping the DEBUG
    /// `eraseDatabaseOnSchemaChange`.
    static func addConversationLocalStateHasHadOtherMembers(_ db: Database) throws {
        try db.alter(table: "conversationLocalState") { t in
            t.add(column: "hasHadOtherMembers", .boolean).notNull().defaults(to: false)
        }
        try db.execute(sql: """
            UPDATE conversationLocalState
            SET hasHadOtherMembers = 1
            WHERE conversationId IN (
                SELECT conversationId FROM conversation_members
                WHERE inboxId NOT IN (SELECT inboxId FROM inbox)
            )
            """)
    }

    /// Filter set of agent-builder bundle message ids hidden from every
    /// client's chat. Intentionally no foreign key to `conversation`: a
    /// manifest can be processed before its conversation row is stored (the
    /// stream routes supplementals ahead of `conversationWriter.store`, and
    /// catch-up can deliver a manifest before the initial conversation sync
    /// lands); a FK would make those inserts fail and silently drop the hidden
    /// ids, leaving the brief visible. A stray row for an absent conversation
    /// matches nothing and is harmless. Teardown clears the table explicitly
    /// in `SessionManager.deleteAllInboxes` (no cascade).
    private static func registerBuilderBundleHiddenMessageMigrations(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("createBuilderBundleHiddenMessage") { db in
            try db.create(table: "builder_bundle_hidden_message") { t in
                t.column("conversationId", .text).notNull()
                t.column("messageId", .text).notNull()
                t.primaryKey(["conversationId", "messageId"])
            }
        }
    }

    /// Pending-leave markers for members who announced a self-removal that
    /// hasn't been finalized yet. No foreign key to `conversation` for the
    /// same reason as `builder_bundle_hidden_message`: a leave-request can
    /// be ingested before the conversation row lands, and a stray row for
    /// an absent conversation matches nothing and is harmless.
    private static func registerMemberDepartureMigrations(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("createMemberDeparture") { db in
            try db.create(table: "member_departure") { t in
                t.column("conversationId", .text).notNull()
                t.column("inboxId", .text).notNull()
                t.column("dateNs", .integer).notNull()
                t.primaryKey(["conversationId", "inboxId"])
            }
        }
    }

    private static func registerConnectionGrantMigrations(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("addConnectionGrantBackendGrantId", migrate: Self.addConnectionGrantBackendGrantId)
        migrator.registerMigration("addConnectionGrantBundleScope", migrate: Self.addConnectionGrantBundleScope)
    }

    /// Tail migrations registered last so they run after every migration above.
    /// Grouped into a helper to keep `createMigrator` under the function-length
    /// budget. Order within: `dropRevealColumns`, the Profile-table schema,
    /// then the catch-up cursor table.
    private static func registerTailMigrations(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("dropRevealColumns", migrate: Self.dropRevealColumns)
        migrator.registerMigration(
            "addConversationLocalStateLeftHostedInviteSession",
            migrate: Self.addConversationLocalStateLeftHostedInviteSession
        )
        migrator.registerMigration(
            "addConversationLocalStateHasHadOtherMembers",
            migrate: Self.addConversationLocalStateHasHadOtherMembers
        )
        migrator.registerMigration(
            "addConversationLocalStateHasSharedInvite",
            migrate: Self.addConversationLocalStateHasSharedInvite
        )
        migrator.registerMigration("createProfileTables", migrate: Self.createProfileTables)
        migrator.registerMigration("createProfileAvatarLatestView", migrate: Self.createProfileAvatarLatestView)
        migrator.registerMigration("dropSelfProfileTable", migrate: Self.dropSelfProfileTable)
        migrator.registerMigration("addProfileAvatarLastRenewed", migrate: Self.addProfileAvatarLastRenewed)
        migrator.registerMigration("makeProfileAvatarLatestViewDeterministic", migrate: Self.makeProfileAvatarLatestViewDeterministic)
        migrator.registerMigration("addConversationLocalStatePublishedProfileUpdatedAt", migrate: Self.addConversationLocalStatePublishedProfileUpdatedAt)
        Self.registerCatchUpCursorMigrations(on: &migrator)
        migrator.registerMigration("createSelfConversationMetadata", migrate: Self.createSelfConversationMetadata)
    }

    /// Additive, nullable column recording the `myProfile.updatedAt` of the self
    /// profile last published to a conversation. The lazy profile sync compares
    /// it against the current `myProfile.updatedAt` to decide whether a profile
    /// edit still needs to be sent to this conversation, so edits reach only
    /// conversations the user re-engages rather than fanning out to all of them.
    /// `nil` means never published (treated as stale), so no backfill is needed.
    /// Guarded on column existence for idempotency across dev installs.
    static func addConversationLocalStatePublishedProfileUpdatedAt(_ db: Database) throws {
        let hasColumn = try db.columns(in: "conversationLocalState").contains { $0.name == "publishedProfileUpdatedAt" }
        guard !hasColumn else { return }
        try db.alter(table: "conversationLocalState") { t in
            t.add(column: "publishedProfileUpdatedAt", .datetime)
        }
    }

    /// Conversation-scoped self metadata (cloud connection grants, agent
    /// timezone), keyed by `(inboxId, conversationId)`. These keys are
    /// per-conversation on the wire, so they cannot live in the global
    /// `myProfile.metadata` map: a global map makes one conversation's grants
    /// overwrite another's and broadcasts them to every conversation. The FK
    /// cascade purges a deleted conversation's rows, matching `profileAvatar`.
    ///
    /// Also strips the scoped keys out of any existing `myProfile.metadata`:
    /// builds that ran the interim global routing wrote grants/timezone there,
    /// and a value left behind would keep broadcasting to every conversation on
    /// each publish. Decoded in Swift rather than `json_remove` so the stored
    /// class (text vs blob) doesn't matter.
    static func createSelfConversationMetadata(_ db: Database) throws {
        try db.create(table: "selfConversationMetadata") { t in
            t.column("inboxId", .text).notNull()
            t.column("conversationId", .text).notNull()
                .references("conversation", onDelete: .cascade)
            t.column("metadata", .jsonText).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.primaryKey(["inboxId", "conversationId"])
        }

        let scopedKeys = ["connections", "timezone"]
        let rows = try Row.fetchAll(db, sql: "SELECT inboxId, metadata FROM myProfile WHERE metadata IS NOT NULL")
        for row in rows {
            let inboxId: String = row["inboxId"]
            let raw: Data?
            if let data = row["metadata"] as Data? {
                raw = data
            } else if let text = row["metadata"] as String? {
                raw = text.data(using: .utf8)
            } else {
                raw = nil
            }
            guard let raw,
                  var metadata = try? JSONDecoder().decode(ProfileMetadata.self, from: raw) else { continue }
            guard scopedKeys.contains(where: { metadata[$0] != nil }) else { continue }
            for key in scopedKeys {
                metadata.removeValue(forKey: key)
            }
            let encoded: String?
            if metadata.isEmpty {
                encoded = nil
            } else {
                let data = try JSONEncoder().encode(metadata)
                encoded = String(bytes: data, encoding: .utf8)
            }
            try db.execute(
                sql: "UPDATE myProfile SET metadata = ? WHERE inboxId = ?",
                arguments: [encoded, inboxId]
            )
        }
    }

    /// Recreates `profileAvatarLatest` with the deterministic `ROW_NUMBER()`
    /// definition. Dev installs that ran the earlier `GROUP BY inboxId` revision
    /// have the nondeterministic view; views carry no data, so a drop+recreate is
    /// safe. Fresh installs already get the deterministic view from
    /// `createProfileAvatarLatestView` and this just recreates it identically.
    static func makeProfileAvatarLatestViewDeterministic(_ db: Database) throws {
        try db.execute(sql: "DROP VIEW IF EXISTS profileAvatarLatest")
        try createProfileAvatarLatestView(db)
    }

    /// Additive, nullable column tracking the last successful asset re-sign time
    /// for a `profileAvatar` URL. Distinct from `updatedAt` (the merge/recency
    /// signal) so the asset renewal sweep can stamp a renewal without making the
    /// avatar look newly authored. `nil` means never renewed (eligible for
    /// renewal), so no backfill is needed. Guarded because fresh installs already
    /// get the column from `createProfileTables`, while dev installs that ran an
    /// earlier revision of it need the `ALTER`.
    static func addProfileAvatarLastRenewed(_ db: Database) throws {
        let hasColumn = try db.columns(in: "profileAvatar").contains { $0.name == "lastRenewed" }
        guard !hasColumn else { return }
        try db.alter(table: "profileAvatar") { t in
            t.add(column: "lastRenewed", .datetime)
        }
    }

    /// Drops the short-lived `selfProfile` table. Self identity was consolidated
    /// onto the pre-existing `myProfile` table, so `selfProfile` is unused.
    /// Guarded on existence because fresh installs never create it (an earlier
    /// revision of `createProfileTables` did), while dev installs that ran that
    /// revision still have it.
    static func dropSelfProfileTable(_ db: Database) throws {
        if try db.tableExists("selfProfile") {
            try db.drop(table: "selfProfile")
        }
    }

    /// Creates the `profileAvatarLatest` view: exactly one deterministic
    /// `profileAvatar` row per inbox - the newest by `updatedAt`, with
    /// `conversationId` as a tie-breaker. The rendering avatar association reads
    /// through this view so every conversation shows a person's latest avatar
    /// (one image per person) rather than the per-conversation slot. Each avatar
    /// row is self-contained (url + salt + nonce + encryptionKey), so its image
    /// decrypts correctly regardless of which conversation is being rendered.
    ///
    /// `ROW_NUMBER()` (not `GROUP BY inboxId`) is required for determinism: when
    /// an inbox has multiple rows at the same `MAX(updatedAt)` - e.g.
    /// `ProfileBackfill` writes every legacy avatar at the epoch floor - a
    /// `GROUP BY` returns bare columns from an arbitrary row in the group, so the
    /// rendered avatar could be from the wrong conversation. The window function
    /// picks one deterministic row per inbox.
    static func createProfileAvatarLatestView(_ db: Database) throws {
        try db.execute(sql: """
            CREATE VIEW IF NOT EXISTS profileAvatarLatest AS
            SELECT inboxId, conversationId, url, salt, nonce, encryptionKey, profileSource, contentDigest, updatedAt
            FROM (
                SELECT inboxId, conversationId, url, salt, nonce, encryptionKey, profileSource, contentDigest, updatedAt,
                       ROW_NUMBER() OVER (
                           PARTITION BY inboxId
                           ORDER BY updatedAt DESC, conversationId DESC
                       ) AS rn
                FROM profileAvatar
            )
            WHERE rn = 1
            """)
    }

    /// Set-once high-water mark: true once the conversation's invite link
    /// was shared externally. The share signal previously lived only in a
    /// view-model latch, so the database-gated discard layers could destroy
    /// a conversation whose invite was already in a recipient's hands (e.g.
    /// share the embedded invite, then scan into another conversation - the
    /// superseded-claim discard reads only database state).
    ///
    /// The column defaults to false with no backfill: shares were never
    /// recorded anywhere queryable (the latch was in-memory only), so
    /// pre-existing shares cannot be reconstructed on upgrade. Those
    /// conversations are typically protected by their other engagement
    /// signals (messages, members, metadata) in practice. Extracted as an
    /// internal static helper so the migration test can exercise the real
    /// upgrade path without tripping the DEBUG `eraseDatabaseOnSchemaChange`.
    static func addConversationLocalStateHasSharedInvite(_ db: Database) throws {
        try db.alter(table: "conversationLocalState") { t in
            t.add(column: "hasSharedInvite", .boolean).notNull().defaults(to: false)
        }
    }

    /// Per-conversation local flag tracking whether the host has navigated
    /// away from an active invite session. The inline Invite/Scan card shows
    /// for a host while this is false and collapses to the regular top cell
    /// once the host leaves the conversation and returns. Stored locally
    /// because it's a per-device UI session state, not consensus state.
    ///
    /// The column default is false ("not left"), so freshly hosted convos
    /// lead with the card. Existing rows are back-filled to true ("already
    /// left") so the newly-inline card does not pop into established hosted
    /// conversations on upgrade.
    static func addConversationLocalStateLeftHostedInviteSession(_ db: Database) throws {
        try db.alter(table: "conversationLocalState") { t in
            t.add(column: "leftHostedInviteSession", .boolean).notNull().defaults(to: false)
        }
        try db.execute(sql: "UPDATE conversationLocalState SET leftHostedInviteSession = 1")
    }

    /// Drops the reveal-mode columns now that incoming media always renders
    /// unblurred. Existing reveal-blurred / owner-hidden rows already render
    /// unblurred since the rendering predicates were removed earlier, so this
    /// migration only drops the now-unused columns. Plain `DROP COLUMN` is
    /// sufficient: none of these columns carry indexes, views, triggers, or
    /// constraints. Extracted as an internal static helper so the migration
    /// test can exercise the real upgrade path without tripping the DEBUG
    /// `eraseDatabaseOnSchemaChange`.
    static func dropRevealColumns(_ db: Database) throws {
        try db.alter(table: "photoPreferences") { t in
            t.drop(column: "autoReveal")
            t.drop(column: "hasRevealedFirst")
        }
        try db.alter(table: "attachmentLocalState") { t in
            t.drop(column: "isRevealed")
            t.drop(column: "revealedAt")
            t.drop(column: "isHiddenByOwner")
        }
    }

    /// In-progress preview identity + narration columns on the direct-builder
    /// generation row. Nullable + additive; preview/`progressPhrases` only
    /// populate while a build runs and are absent once terminal.
    private static func addAgentTemplateGenerationPreview(_ db: Database) throws {
        try db.alter(table: "agentTemplateGeneration") { t in
            t.add(column: "previewAgentName", .text)
            t.add(column: "previewEmoji", .text)
            t.add(column: "previewDescription", .text)
            t.add(column: "progressPhrases", .text)
        }
    }

    /// Additive, nullable column holding a JSON-encoded
    /// `[StoredGenerationAttachment]` for media inputs. `nil` for text-only
    /// builds, so existing rows are unaffected.
    private static func addAgentTemplateGenerationAttachments(_ db: Database) throws {
        try db.alter(table: "agentTemplateGeneration") { t in
            t.add(column: "attachments", .text)
        }
    }

    /// Additive, nullable column holding a JSON-encoded `[String]` of neutral
    /// connection service ids sent with the generation. `nil` when no
    /// connections, so existing rows are unaffected.
    private static func addAgentTemplateGenerationConnections(_ db: Database) throws {
        try db.alter(table: "agentTemplateGeneration") { t in
            t.add(column: "connections", .text)
        }
    }

    /// Additive, nullable column holding the dev-only agent variant slug the
    /// build was captured under. Persisted on the row so the same value rides
    /// the generation, join, and join-status-poll calls even across a relaunch
    /// resume, instead of re-reading the device selection mid-build. `nil` for
    /// default (non-variant) builds, so existing rows are unaffected.
    private static func addAgentTemplateGenerationVariant(_ db: Database) throws {
        try db.alter(table: "agentTemplateGeneration") { t in
            t.add(column: "variantId", .text)
        }
    }

    /// Additive, nullable column holding the join idempotency key sent on
    /// `POST /v2/agents/join` (lowercase v4 UUID). Persisted before the first
    /// join attempt so a retry after a lost response - including a relaunch
    /// resume - resends the same key and the server adopts the in-flight
    /// instance instead of provisioning a duplicate. `nil` until the invite
    /// step runs, so existing rows are unaffected.
    private static func addAgentTemplateGenerationJoinIdempotencyKey(_ db: Database) throws {
        try db.alter(table: "agentTemplateGeneration") { t in
            t.add(column: "joinIdempotencyKey", .text)
        }
    }

    /// Registers the join-request ledger and the direct-builder generation
    /// table, in this order. Grouped into a helper to keep `makeMigrator`
    /// under the function-length budget; the registration position (last,
    /// before `return`) is unchanged so the migration order is preserved.
    private static func registerJoinAndGenerationMigrations(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("createHandledJoinRequest", migrate: Self.createHandledJoinRequest)
        migrator.registerMigration("createAgentTemplateGeneration", migrate: Self.createAgentTemplateGeneration)
        migrator.registerMigration("addAgentTemplateGenerationPreview", migrate: Self.addAgentTemplateGenerationPreview)
        migrator.registerMigration("addAgentTemplateGenerationAttachments", migrate: Self.addAgentTemplateGenerationAttachments)
        migrator.registerMigration("addAgentTemplateGenerationConnections", migrate: Self.addAgentTemplateGenerationConnections)
        migrator.registerMigration("addAgentTemplateGenerationVariant", migrate: Self.addAgentTemplateGenerationVariant)
        migrator.registerMigration("addAgentTemplateGenerationJoinIdempotencyKey", migrate: Self.addAgentTemplateGenerationJoinIdempotencyKey)
    }

    /// In-flight (or finished) agent-template generation kicked off by the
    /// direct builder flow. Persisting it makes a build survive sheet
    /// dismissal / app restart so the repository can resume polling or
    /// re-issue the invite. Keyed by the client-generated `idempotencyKey`
    /// (stable before the server responds, so a crash before the POST returns
    /// replays safely); the server's `generationId` is filled in after submit.
    /// The `conversationId` index backs the per-conversation publisher the
    /// pending UI observes.
    private static func createAgentTemplateGeneration(_ db: Database) throws {
        try db.create(table: "agentTemplateGeneration") { t in
            t.column("idempotencyKey", .text).notNull().primaryKey()
            t.column("generationId", .text)
            t.column("conversationId", .text).notNull()
            t.column("slug", .text).notNull()
            t.column("status", .text).notNull()
            t.column("templateId", .text)
            t.column("prompt", .text).notNull()
            t.column("error", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(
            index: "agentTemplateGeneration_conversationId",
            on: "agentTemplateGeneration",
            columns: ["conversationId"]
        )
    }

    /// Ledger of join-request message IDs that already admitted their
    /// sender, shared with the notification service extension. Keyed by
    /// message ID so revalidation passes cannot re-add a member the user
    /// removed; see `DatabaseHandledJoinRequestStore`.
    private static func createHandledJoinRequest(_ db: Database) throws {
        try db.create(table: "handledJoinRequest") { t in
            t.column("messageId", .text).notNull().primaryKey()
            t.column("handledAt", .datetime).notNull()
        }
        try db.create(
            index: "handledJoinRequest_handledAt",
            on: "handledJoinRequest",
            columns: ["handledAt"]
        )
    }

    /// Persisted "the local user was removed from this conversation" marker.
    /// Removal was previously hidden only in-memory
    /// (ConversationsViewModel.hiddenConversationIds), so a relaunch
    /// resurrected a conversation whose XMTP group is inactive - visible
    /// history but every send failing. The `.notNull().defaults(to: false)`
    /// clause back-fills existing rows with `false`, matching the legacy
    /// (visible) behavior for conversations the user was never removed from.
    private static func registerRemovedStateMigrations(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("addConversationLocalStateWasRemoved") { db in
            try db.alter(table: "conversationLocalState") { t in
                t.add(column: "wasRemoved", .boolean).notNull().defaults(to: false)
            }
        }
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

    /// Marks a summary as belonging to a conversation the user was already in
    /// (the in-chat "New Agent" entry) rather than a fresh home-flow agent
    /// chat. The chat keeps its invite affordances (QR / "Invite members")
    /// visible while this summary's card shows, instead of suppressing them
    /// the way the home flow does. Defaults to false for existing rows.
    private static func addAgentBuilderSummaryExistingConversation(_ db: Database) throws {
        try db.alter(table: "agentBuilderSummary") { t in
            t.add(column: "existingConversation", .boolean).notNull().defaults(to: false)
        }
    }

    private static func dropConversationQuarantineFields(_ db: Database) throws {
        try db.alter(table: "conversation") { t in
            t.drop(column: "quarantinedAt")
            t.drop(column: "quarantineReleasedAt")
        }
    }

    /// Template identity for template-backed agent contacts, mirrored from
    /// the per-conversation member profile so it survives leaving the
    /// conversation. The partial index keeps a future "group contacts by
    /// template" query index-backed without a schema change - only agent
    /// rows carry a non-null templateId.
    private static func addContactAgentTemplateFields(_ db: Database) throws {
        try db.alter(table: "contact") { t in
            t.add(column: "agentTemplateId", .text)
            t.add(column: "agentTemplatePublishedURL", .text)
            t.add(column: "agentTemplateEmoji", .text)
        }
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS contact_on_agentTemplateId
            ON contact(agentTemplateId)
            WHERE agentTemplateId IS NOT NULL
            """)
    }

    /// Backfill the agent-template columns added by `addContactAgentTemplateFields`
    /// for contacts that predate them. A template-backed agent's `templateId` (and
    /// `publishedUrl` / `emoji`) is already on disk in its per-conversation
    /// `memberProfile.metadata`; without this, an existing agent contact keeps a
    /// null `agentTemplateId` and `Contact.isVisibleInContactsList` hides it until a
    /// fresh `ProfileUpdate` re-mirrors the value - which never fires at launch for
    /// an agent that is not actively messaging, so the contact would stay hidden
    /// indefinitely. Decodes the raw metadata JSON with `ProfileMetadata` (the
    /// canonical wire type) rather than a record type, so the migration stays
    /// reproducible if `memberProfile`'s columns change later. An inbox can have
    /// several `memberProfile` rows; the `agentTemplateId IS NULL` guard makes the
    /// first one carrying a templateId win and the rest no-ops.
    static func backfillContactAgentTemplateFieldsFromMemberProfiles(_ db: Database) throws {
        let decoder = JSONDecoder()
        let rows = try Row.fetchCursor(db, sql: "SELECT inboxId, metadata FROM memberProfile WHERE metadata IS NOT NULL")
        while let row = try rows.next() {
            guard let json: String = row["metadata"],
                  let metadata = try? decoder.decode(ProfileMetadata.self, from: Data(json.utf8)),
                  let templateId = trimmedMetadataValue(metadata, "templateId") else {
                continue
            }
            let inboxId: String = row["inboxId"]
            try db.execute(
                sql: """
                    UPDATE contact
                    SET agentTemplateId = ?, agentTemplatePublishedURL = ?, agentTemplateEmoji = ?
                    WHERE inboxId = ? AND agentTemplateId IS NULL
                    """,
                arguments: [
                    templateId,
                    trimmedMetadataValue(metadata, "publishedUrl"),
                    trimmedMetadataValue(metadata, "emoji"),
                    inboxId,
                ]
            )
        }
    }

    /// Reads a metadata string value, coercing empty / whitespace-only to nil.
    /// Mirrors `DBMemberProfile.trimmedMetadata` so a backfilled templateId never
    /// lands as "" (which would collapse unrelated agents in the dedup pipeline).
    private static func trimmedMetadataValue(_ metadata: ProfileMetadata, _ key: String) -> String? {
        metadata[key]?.stringValue.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Read-through cache of canonical agent-template identity (name, emoji,
    /// avatar), keyed by templateId. Lets the contacts list collapse a
    /// template's running instances into one stable row.
    private static func createAgentTemplateCache(_ db: Database) throws {
        try db.create(table: "agentTemplate") { t in
            t.column("templateId", .text).notNull().primaryKey()
            t.column("agentName", .text)
            t.column("emoji", .text)
            t.column("avatarURL", .text)
            t.column("publishedURL", .text)
            t.column("fetchedAt", .datetime).notNull()
        }
    }

    /// Adds the `description` and `slug` columns to the agent-template cache.
    /// The detail endpoint (`GET /v2/agent-templates/:idOrUrlSlug`) returns
    /// both; storing them lets the agent-share resolver render a card's
    /// subtitle from cache and look the cache up by slug, not just by template
    /// id (share links are often slug-keyed). The slug index keeps that
    /// lookup cheap; it's partial so null slugs (rows cached before this
    /// migration, until they're refreshed) don't bloat it.
    private static func addAgentTemplateDescriptionAndSlug(_ db: Database) throws {
        try db.alter(table: "agentTemplate") { t in
            t.add(column: "description", .text)
            t.add(column: "slug", .text)
        }
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS agentTemplate_on_slug
            ON agentTemplate(slug)
            WHERE slug IS NOT NULL
            """)
    }

    /// Id of the backend ConnectionGrant record (POST /v2/connections/grants)
    /// created when a local grant is pushed to the server. Nullable: rows
    /// that predate the backend push, or whose push failed, have no backend
    /// id and are skipped during backend revocation.
    private static func addConnectionGrantBackendGrantId(_ db: Database) throws {
        try db.alter(table: "connectionGrant") { t in
            t.add(column: "backendGrantId", .text)
        }
    }

    /// Bundle-scoped grants (connections picker): `bundleIds` is the JSON
    /// array of permission-bundle ids the user toggled on (catalog ids like
    /// "calendar.events"); `serviceVersion` is the catalog version the device
    /// granted against. Both nullable: rows that predate bundles, or whose
    /// service isn't in the catalog, are legacy whole-toolkit grants.
    private static func addConnectionGrantBundleScope(_ db: Database) throws {
        try db.alter(table: "connectionGrant") { t in
            t.add(column: "bundleIds", .text)
            t.add(column: "serviceVersion", .integer)
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

    /// The templateId-keyed agent-template contact table. Separate from the
    /// inboxId-keyed `contact` table because a template instantiated into N
    /// conversations produces N distinct agent inboxIds - the stable
    /// identity of the contact is the template. Registered after the
    /// contacts-MVP migrations so the `addedViaConversationId` foreign key
    /// against `conversation` resolves.
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
    /// column: agent-template contacts support Remove only - see the
    /// agent-templates PRD.
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

    /// Creates the canonical Profile-table schema that replaces per-conversation
    /// `memberProfile` identity: `profile` (per-person name/kind/metadata),
    /// `profileAvatar` (per-`(inboxId, conversationId)` encrypted avatar slot),
    /// `selfProfile` (the local user's authored identity), `profileAvatarSource`
    /// (the user's plaintext source image), and `profilePublishJob` (durable
    /// publish queue). Additive: nothing reads these tables until the
    /// `ProfilesRepository` lands. `avatarContentDigest` / `contentDigest` are
    /// reserved for the cross-conversation digest optimization (ADR 014) and stay
    /// nil until that work ships. Extracted as an internal static helper so the
    /// migration test can drive the real create path without tripping the DEBUG
    /// `eraseDatabaseOnSchemaChange`.
    static func createProfileTables(_ db: Database) throws {
        try db.create(table: "profile") { t in
            t.column("inboxId", .text).notNull().primaryKey()
            t.column("name", .text)
            t.column("memberKind", .text)
            t.column("metadata", .jsonText)
            t.column("profileSource", .text).notNull()
            t.column("avatarContentDigest", .text)
            t.column("updatedAt", .datetime).notNull()
        }

        try db.create(table: "profileAvatar") { t in
            t.column("inboxId", .text).notNull()
            t.column("conversationId", .text).notNull()
                .references("conversation", onDelete: .cascade)
            t.column("url", .text)
            t.column("salt", .blob)
            t.column("nonce", .blob)
            t.column("encryptionKey", .blob)
            t.column("profileSource", .text).notNull()
            t.column("contentDigest", .text)
            t.column("updatedAt", .datetime).notNull()
            t.column("lastRenewed", .datetime)
            t.primaryKey(["inboxId", "conversationId"])
        }

        try db.create(table: "profileAvatarSource") { t in
            t.column("inboxId", .text).notNull().primaryKey()
            t.column("plaintext", .blob).notNull()
            t.column("version", .integer).notNull()
            t.column("updatedAt", .datetime).notNull()
        }

        try db.create(table: "profilePublishJob") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("seq", .integer).notNull()
            t.column("conversationId", .text).notNull()
                .references("conversation", onDelete: .cascade)
            t.column("sourceVersion", .integer)
            t.column("hasAvatar", .boolean).notNull().defaults(to: false)
            t.column("state", .text).notNull().defaults(to: ProfilePublishJobState.pending.rawValue)
            t.column("ciphertext", .blob)
            t.column("salt", .blob)
            t.column("nonce", .blob)
            t.column("groupKey", .blob)
            t.column("filename", .text)
            t.column("uploadedURL", .text)
            t.column("attemptCount", .integer).notNull().defaults(to: 0)
            t.column("nextAttemptAt", .datetime).notNull()
            t.column("lastError", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }

        try db.create(
            index: "profilePublishJob_ready",
            on: "profilePublishJob",
            columns: ["state", "nextAttemptAt", "seq"]
        )
        try db.create(
            index: "profilePublishJob_conversationId",
            on: "profilePublishJob",
            columns: ["conversationId"]
        )
    }
}
