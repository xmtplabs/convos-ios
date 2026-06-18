import Foundation
import GRDB

// `block` flips feed visibility synchronously: in one DB transaction it
// sets the contact's `blockedAt` and demotes the creator's conversations
// to `.denied`. The feed is a GRDB observation on the `consent` column, so
// it hides on commit with no network in the path - the user never sees a
// blocked contact's chats linger. The XMTP-side consent flip then runs
// best-effort afterward purely for cross-device + re-sync durability;
// failures are logged, not thrown, because the local feed is already
// correct. `ConversationConsentReconciler` stays as a backstop that only
// re-fires when re-sync rewrites the DB `consent` column back to `.allowed`.
//
// `unblock` remains a pure contact-row write. By policy a `.denied`
// conversation is never auto-promoted (the user effectively deleted it),
// so unblocking does not restore conversations hidden while blocked.

/// Snapshot of profile fields used when upserting a contact. Callers pass
/// the most recent snapshot they have for the inbox. A timestamped
/// snapshot (`profileUpdatedAt != nil`) is treated as one authoritative
/// unit: `replacingProfile(of:with:)` wholesale-replaces every field on
/// the stored row, including `nil`s. An untimestamped snapshot is a
/// fill-defaults payload from a local hydration site
/// (`ContactSyncCoordinator`, `ContactDetailView.handleSendMessage`); it
/// only seeds new contact rows and never updates an existing one.
public struct ContactProfileSnapshot: Sendable, Hashable {
    public let displayName: String?
    public let avatarURL: String?
    /// AES-256-GCM decryption material for the encrypted avatar at
    /// `avatarURL`. Travels alongside the URL so mirror writes can keep
    /// the contact's avatar decodable. Wholesale-replaced along with the
    /// other profile fields when a timestamped snapshot applies.
    public let avatarSalt: Data?
    public let avatarNonce: Data?
    public let avatarKey: Data?
    public let profileUpdatedAt: Date?
    public let agentVerification: AgentVerification?
    /// Template identity for a template-backed agent, mirrored onto the
    /// contact so it survives leaving the conversation. `nil` for humans.
    public let agentTemplateId: String?
    public let agentTemplatePublishedURL: String?
    public let agentTemplateEmoji: String?

    public init(
        displayName: String? = nil,
        avatarURL: String? = nil,
        avatarSalt: Data? = nil,
        avatarNonce: Data? = nil,
        avatarKey: Data? = nil,
        profileUpdatedAt: Date? = nil,
        agentVerification: AgentVerification? = nil,
        agentTemplateId: String? = nil,
        agentTemplatePublishedURL: String? = nil,
        agentTemplateEmoji: String? = nil
    ) {
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.avatarSalt = avatarSalt
        self.avatarNonce = avatarNonce
        self.avatarKey = avatarKey
        self.profileUpdatedAt = profileUpdatedAt
        self.agentVerification = agentVerification
        self.agentTemplateId = agentTemplateId
        self.agentTemplatePublishedURL = agentTemplatePublishedURL
        self.agentTemplateEmoji = agentTemplateEmoji
    }
}

public protocol ContactsWriterProtocol: Sendable {
    /// Idempotent upsert. If the contact already exists, the immutable
    /// identity columns (`addedAt`, `addedViaConversationId`) are preserved
    /// and only the profile snapshot is updated subject to most-recent-wins.
    func upsertContact(
        inboxId: String,
        addedViaConversationId: String?,
        profile: ContactProfileSnapshot
    ) async throws

    /// Most-recent-wins profile update. Applied only if the incoming
    /// `profileUpdatedAt` is newer than the stored value (or the stored value
    /// is nil). No-op when the snapshot is untimestamped.
    func updateProfileIfNewer(
        inboxId: String,
        profile: ContactProfileSnapshot
    ) async throws

    /// Marks the contact as blocked and synchronously demotes the creator's
    /// still-visible conversations to `.denied` in the same transaction, so
    /// the feed hides them immediately (no network in the path). The
    /// XMTP-side consent flip runs best-effort afterward for cross-device
    /// durability. No-op if the inboxId has no contact row (blocking does
    /// not auto-create contacts). Repeat calls leave the original
    /// `blockedAt` timestamp in place but still re-demote any conversation
    /// that drifted back to visible.
    func block(inboxId: String) async throws

    /// Clears the blocked flag on the contact. No-op if the inboxId has no
    /// contact row or is already unblocked.
    func unblock(inboxId: String) async throws
}

final class ContactsWriter: ContactsWriterProtocol, @unchecked Sendable {
    private let databaseWriter: any DatabaseWriter
    /// Used by `block` to flip XMTP consent after the synchronous DB demote.
    /// Optional so pure-DB unit tests can construct the writer without a
    /// live session; when nil the XMTP flip is skipped and the
    /// `ConversationConsentReconciler` backstop covers durability.
    private let sessionStateManager: (any SessionStateManagerProtocol)?

    init(
        databaseWriter: any DatabaseWriter,
        sessionStateManager: (any SessionStateManagerProtocol)? = nil
    ) {
        self.databaseWriter = databaseWriter
        self.sessionStateManager = sessionStateManager
    }

    func upsertContact(
        inboxId: String,
        addedViaConversationId: String?,
        profile: ContactProfileSnapshot
    ) async throws {
        try await databaseWriter.write { db in
            try Self.upsert(
                db: db,
                inboxId: inboxId,
                addedViaConversationId: addedViaConversationId,
                profile: profile
            )
        }
    }

    func updateProfileIfNewer(
        inboxId: String,
        profile: ContactProfileSnapshot
    ) async throws {
        try await databaseWriter.write { db in
            guard let existing = try DBContact.fetchOne(db, key: inboxId) else {
                // No contact row to update; profile updates for non-contacts
                // are intentionally dropped (the contacts feature is action-
                // gated and we never auto-add from a profile event alone).
                return
            }
            guard let merged = Self.replacingProfile(of: existing, with: profile) else {
                return
            }
            try merged.save(db)
        }
    }

    func block(inboxId: String) async throws {
        let demotedConversationIds: [String] = try await databaseWriter.write { db in
            guard let existing = try DBContact.fetchOne(db, key: inboxId) else {
                // Blocking is action-gated on an existing contact row. We
                // never auto-create a contact just to flag it as blocked.
                Log.debug("block(inboxId:) skipped, no contact row for \(inboxId)")
                return []
            }
            // Idempotent: only stamp blockedAt on the first block, but always
            // demote any still-visible conversations (a repeat block heals a
            // conversation that drifted back to visible via re-sync).
            if existing.blockedAt == nil {
                try existing.with(blockedAt: Date()).save(db)
            }
            return try Self.demoteVisibleConversations(db: db, creatorId: inboxId)
        }
        // Feed is already hidden (window 0). Flip XMTP consent best-effort for
        // cross-device + re-sync durability; the local DB is authoritative so
        // a failure here is logged, not thrown, and the reconciler backstop
        // re-converges if re-sync later reverts the DB column.
        guard let sessionStateManager, !demotedConversationIds.isEmpty else {
            return
        }
        do {
            let client = try await sessionStateManager.waitForInboxReadyResult().client
            for conversationId in demotedConversationIds {
                do {
                    // Retry transient failures (a momentary network blip). The
                    // local feed is already correct, so an exhausted retry just
                    // logs; re-sync drift is then caught by the reconciler
                    // backstop, which itself re-runs on app foreground and on
                    // network reconnect (SessionStateMachine -> resume).
                    try await withExponentialBackoffRetry {
                        try await client.update(consent: .denied, for: conversationId)
                    }
                } catch {
                    Log.error("block(inboxId:) XMTP consent flip failed for \(conversationId): \(error.localizedDescription)")
                }
            }
        } catch {
            Log.error("block(inboxId:) could not obtain client for XMTP consent flip: \(error.localizedDescription)")
        }
    }

    /// Demotes every still-visible conversation created by `creatorId` to
    /// `.denied` and returns their ids. Mirrors the
    /// `ConversationConsentReconciler` join (`conversation.creatorId =
    /// contact.inboxId`), so shared groups the local user created stay
    /// visible. Conversations already `.denied` are left untouched.
    private static func demoteVisibleConversations(db: Database, creatorId: String) throws -> [String] {
        let conversationIds: [String] = try DBConversation
            .filter(DBConversation.Columns.creatorId == creatorId)
            .filter(DBConversation.Columns.consent != Consent.denied)
            .fetchAll(db)
            .map(\.id)
        guard !conversationIds.isEmpty else {
            return []
        }
        try DBConversation
            .filter(conversationIds.contains(DBConversation.Columns.id))
            .updateAll(db, DBConversation.Columns.consent.set(to: Consent.denied))
        return conversationIds
    }

    func unblock(inboxId: String) async throws {
        try await databaseWriter.write { db in
            guard let existing = try DBContact.fetchOne(db, key: inboxId) else {
                Log.debug("unblock(inboxId:) skipped, no contact row for \(inboxId)")
                return
            }
            guard existing.blockedAt != nil else {
                return
            }
            try existing.with(blockedAt: nil).save(db)
        }
        // `ConversationConsentReconciler` observes the `contact` table and
        // restores this creator's conversations to `.allowed`.
    }

    fileprivate static func upsert(
        db: Database,
        inboxId: String,
        addedViaConversationId: String?,
        profile: ContactProfileSnapshot
    ) throws {
        if let existing = try DBContact.fetchOne(db, key: inboxId) {
            // Identity columns (addedAt, addedViaConversationId) are
            // intentionally preserved on re-upsert. The profile snapshot is
            // applied only if it carries a `profileUpdatedAt` newer than
            // the stored one (see `replacingProfile`); untimestamped
            // re-upserts leave the existing row untouched.
            guard let merged = replacingProfile(of: existing, with: profile) else {
                return
            }
            try merged.save(db)
            return
        }

        let now = Date()
        let row = DBContact(
            inboxId: inboxId,
            addedAt: now,
            addedViaConversationId: addedViaConversationId,
            displayName: profile.displayName,
            avatarURL: profile.avatarURL,
            avatarSalt: profile.avatarSalt,
            avatarNonce: profile.avatarNonce,
            avatarKey: profile.avatarKey,
            profileUpdatedAt: profile.profileUpdatedAt ?? now,
            agentVerification: profile.agentVerification,
            agentTemplateId: profile.agentTemplateId,
            agentTemplatePublishedURL: profile.agentTemplatePublishedURL,
            agentTemplateEmoji: profile.agentTemplateEmoji
        )
        try row.save(db)
        Log.debug("Inserted new contact for inboxId=\(inboxId) via=\(addedViaConversationId ?? "nil")")
    }

    /// Returns `existing` with its profile fields replaced by `profile` if
    /// the snapshot should be applied; returns `nil` if the caller should
    /// leave the stored row untouched.
    ///
    /// The snapshot is treated as one authoritative unit: when applied,
    /// every profile field on the stored row is replaced by the snapshot's
    /// value (including `nil`s, which clear the stored field). There is no
    /// per-field merging. This matches the wire-format contract for
    /// `ProfileUpdate`, where a message with no name and no encrypted
    /// image clears the sender's profile.
    ///
    /// Application rules:
    /// - Untimestamped snapshots (`profile.profileUpdatedAt == nil`) never
    ///   update an existing row. The caller is in a fill-defaults context
    ///   (e.g. `ContactSyncCoordinator` reading per-conversation member
    ///   profiles) and the stored row is authoritative.
    /// - Timestamped snapshots older than the stored `profileUpdatedAt`
    ///   are dropped (most-recent-wins).
    /// - Timestamped snapshots greater-than-or-equal to the stored
    ///   timestamp wholesale-replace every profile field on the row.
    private static func replacingProfile(
        of existing: DBContact,
        with profile: ContactProfileSnapshot
    ) -> DBContact? {
        guard let incomingTimestamp = profile.profileUpdatedAt else {
            return nil
        }
        if let stored = existing.profileUpdatedAt, incomingTimestamp < stored {
            return nil
        }
        return existing.replacingProfileFields(with: profile, at: incomingTimestamp)
    }
}

/// In-transaction helpers for contact upserts and for mirroring `DBMemberProfile`
/// saves onto `DBContact` (`mirrorMemberProfileToContactInTransaction`,
/// `saveMemberProfileAndMirrorToContactInTransaction`).
extension ContactsWriter {
    static func upsertContactInTransaction(
        db: Database,
        inboxId: String,
        addedViaConversationId: String?,
        profile: ContactProfileSnapshot
    ) throws {
        try upsert(
            db: db,
            inboxId: inboxId,
            addedViaConversationId: addedViaConversationId,
            profile: profile
        )
    }

    /// Copies member-profile display fields (including AES-256-GCM avatar
    /// material) onto the matching contact row inside an existing
    /// transaction. No-ops when there is no contact for `inboxId` (profile
    /// events never auto-add contacts; only the action-gated coordinator
    /// does), or when `receivedAt` is older than the stored
    /// `profileUpdatedAt`.
    ///
    /// When the snapshot applies, every profile field on the row is
    /// replaced wholesale: a `nil` `agentVerification` argument clears any
    /// previously stored verification, matching the `ProfileUpdate`
    /// wire-format contract.
    static func mirrorMemberProfileToContactInTransaction(
        db: Database,
        inboxId: String,
        name: String?,
        avatarURL: String?,
        avatarSalt: Data? = nil,
        avatarNonce: Data? = nil,
        avatarKey: Data? = nil,
        receivedAt: Date,
        agentVerification: AgentVerification? = nil,
        agentTemplateId: String? = nil,
        agentTemplatePublishedURL: String? = nil,
        agentTemplateEmoji: String? = nil
    ) throws {
        guard let existing = try DBContact.fetchOne(db, key: inboxId) else {
            return
        }
        let snapshot = ContactProfileSnapshot(
            displayName: name,
            avatarURL: avatarURL,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce,
            avatarKey: avatarKey,
            profileUpdatedAt: receivedAt,
            agentVerification: agentVerification,
            agentTemplateId: agentTemplateId,
            agentTemplatePublishedURL: agentTemplatePublishedURL,
            agentTemplateEmoji: agentTemplateEmoji
        )
        guard let merged = replacingProfile(of: existing, with: snapshot) else {
            return
        }
        try merged.save(db)
    }

    /// Persists `profile` and mirrors name/avatar (including the AES-256-GCM
    /// salt/nonce/key) onto the matching `DBContact` in the same transaction.
    /// Prefer this over `profile.save(db)` plus a separate mirror call so
    /// callers cannot skip the contact-list sync.
    static func saveMemberProfileAndMirrorToContactInTransaction(
        db: Database,
        profile: DBMemberProfile,
        receivedAt: Date
    ) throws {
        try profile.save(db)
        try mirrorMemberProfileToContactInTransaction(
            db: db,
            inboxId: profile.inboxId,
            name: profile.name,
            avatarURL: profile.avatar,
            avatarSalt: profile.avatarSalt,
            avatarNonce: profile.avatarNonce,
            avatarKey: profile.avatarKey,
            receivedAt: receivedAt,
            agentVerification: profile.memberKind?.agentVerification,
            agentTemplateId: profile.agentTemplateId,
            agentTemplatePublishedURL: profile.agentTemplatePublishedURL,
            agentTemplateEmoji: profile.agentTemplateEmoji
        )
    }

    /// Most-recent-wins apply for an inbound member profile (live stream,
    /// history replay, or push extension). Drops the write when `incomingSentAt`
    /// is older than the row's stored `profileUpdatedAt`, so a stale or replayed
    /// message can never clobber newer data. When applied, stamps the row with
    /// `incomingSentAt`, persists it, and mirrors to `DBContact` in the same
    /// transaction so the member row and contact row can never diverge.
    ///
    /// `incomingSentAt` is the sender's `message.sentAt` (sender clock); this
    /// accepts sender-clock ordering, identical to the `DBContact` guard in
    /// `replacingProfile(of:with:)`. Equal-or-newer applies (the equal case is
    /// the idempotent reprocess of the same message). Returns true when applied,
    /// false when dropped as stale.
    @discardableResult
    static func applyInboundMemberProfileInTransaction(
        db: Database,
        profile: DBMemberProfile,
        incomingSentAt: Date
    ) throws -> Bool {
        let stored = try DBMemberProfile.fetchOne(
            db,
            conversationId: profile.conversationId,
            inboxId: profile.inboxId
        )?.profileUpdatedAt
        if let stored, incomingSentAt < stored {
            return false
        }
        let stamped = profile.with(profileUpdatedAt: incomingSentAt)
        try saveMemberProfileAndMirrorToContactInTransaction(
            db: db,
            profile: stamped,
            receivedAt: incomingSentAt
        )
        return true
    }
}
