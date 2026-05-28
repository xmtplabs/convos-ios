import Foundation
import GRDB

public extension Notification.Name {
    /// Posted on the main queue by `ContactsWriter.block` / `unblock` when
    /// a contact's blocked state actually changes (idempotent no-ops do
    /// not fire). `SessionManager` observes this to run an immediate
    /// `QuarantineSweeper.sweep()`; unblocking should restore held-by-
    /// block conversations to the main feed without waiting for the next
    /// hourly or foreground-entry sweep. UserInfo:
    /// `inboxId: String`, `blocked: Bool`.
    static let contactBlockingDidChange: Notification.Name = Notification.Name(
        "ContactBlockingDidChange"
    )

    /// Posted on the main queue after one or more brand-new `DBContact`
    /// rows are committed. Idempotent re-upserts and profile-only updates
    /// do not fire. `SessionManager` observes this to trigger an
    /// immediate `QuarantineSweeper.sweep()` so a conversation that was
    /// held in quarantine because its creator was a stranger is promoted
    /// to the main feed as soon as the creator is added as a contact,
    /// without waiting for the next hourly or foreground-entry sweep.
    ///
    /// Batch callers (e.g. `ContactSyncCoordinator` syncing every
    /// non-self member of a group when the local user first acts there)
    /// collect inserted inboxIds inside their transaction and emit a
    /// single notification after the write commits. UserInfo:
    /// `inboxIds: [String]`.
    static let contactsWereAdded: Notification.Name = Notification.Name(
        "ContactsWereAdded"
    )
}

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

    public init(
        displayName: String? = nil,
        avatarURL: String? = nil,
        avatarSalt: Data? = nil,
        avatarNonce: Data? = nil,
        avatarKey: Data? = nil,
        profileUpdatedAt: Date? = nil,
        agentVerification: AgentVerification? = nil
    ) {
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.avatarSalt = avatarSalt
        self.avatarNonce = avatarNonce
        self.avatarKey = avatarKey
        self.profileUpdatedAt = profileUpdatedAt
        self.agentVerification = agentVerification
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

    /// Marks the contact as blocked. No-op if the inboxId has no contact row
    /// (blocking does not auto-create contacts) or is already blocked. Repeat
    /// calls leave the original `blockedAt` timestamp in place.
    func block(inboxId: String) async throws

    /// Clears the blocked flag on the contact. No-op if the inboxId has no
    /// contact row or is already unblocked.
    func unblock(inboxId: String) async throws
}

final class ContactsWriter: ContactsWriterProtocol, @unchecked Sendable {
    private let databaseWriter: any DatabaseWriter

    init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    func upsertContact(
        inboxId: String,
        addedViaConversationId: String?,
        profile: ContactProfileSnapshot
    ) async throws {
        let didInsert: Bool = try await databaseWriter.write { db in
            try Self.upsert(
                db: db,
                inboxId: inboxId,
                addedViaConversationId: addedViaConversationId,
                profile: profile
            )
        }
        if didInsert {
            ContactsWriter.postContactsWereAdded(inboxIds: [inboxId])
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
        let didChange: Bool = try await databaseWriter.write { db in
            guard let existing = try DBContact.fetchOne(db, key: inboxId) else {
                // Blocking is action-gated on an existing contact row. We
                // never auto-create a contact just to flag it as blocked.
                Log.debug("block(inboxId:) skipped, no contact row for \(inboxId)")
                return false
            }
            guard existing.blockedAt == nil else {
                // Idempotent: leave the original blockedAt timestamp.
                return false
            }
            try existing.with(blockedAt: Date()).save(db)
            return true
        }
        if didChange {
            ContactsWriter.postBlockingDidChange(inboxId: inboxId, blocked: true)
        }
    }

    func unblock(inboxId: String) async throws {
        let didChange: Bool = try await databaseWriter.write { db in
            guard let existing = try DBContact.fetchOne(db, key: inboxId) else {
                Log.debug("unblock(inboxId:) skipped, no contact row for \(inboxId)")
                return false
            }
            guard existing.blockedAt != nil else {
                return false
            }
            try existing.with(blockedAt: nil).save(db)
            return true
        }
        if didChange {
            ContactsWriter.postBlockingDidChange(inboxId: inboxId, blocked: false)
        }
    }

    /// Posted on the main queue after `block` / `unblock` writes a real
    /// state change (idempotent no-ops do not fire). `SessionManager`
    /// observes this to trigger an immediate `QuarantineSweeper.sweep()`
    /// so unblocking restores held-by-block conversations to the main
    /// feed without waiting for the next hourly/foreground sweep.
    private static func postBlockingDidChange(inboxId: String, blocked: Bool) {
        let userInfo: [String: Any] = ["inboxId": inboxId, "blocked": blocked]
        if Thread.isMainThread {
            NotificationCenter.default.post(
                name: .contactBlockingDidChange,
                object: nil,
                userInfo: userInfo
            )
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .contactBlockingDidChange,
                    object: nil,
                    userInfo: userInfo
                )
            }
        }
    }

    /// Posted on the main queue after one or more brand-new contact rows
    /// are committed. Callers in a batch context (e.g.
    /// `ContactSyncCoordinator`) accumulate inserted inboxIds inside
    /// their `databaseWriter.write` closure and call this once after the
    /// write returns, so the eventual `QuarantineSweeper.sweep()` sees
    /// committed contact rows.
    ///
    /// No-op on an empty array so batch callers can call unconditionally
    /// after their transaction.
    static func postContactsWereAdded(inboxIds: [String]) {
        guard !inboxIds.isEmpty else { return }
        let userInfo: [String: Any] = ["inboxIds": inboxIds]
        if Thread.isMainThread {
            NotificationCenter.default.post(
                name: .contactsWereAdded,
                object: nil,
                userInfo: userInfo
            )
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .contactsWereAdded,
                    object: nil,
                    userInfo: userInfo
                )
            }
        }
    }

    /// Returns `true` when this call inserted a brand-new `DBContact` row
    /// for `inboxId`, `false` when an existing row was merged-into (or
    /// left untouched). Callers use the return value to decide whether
    /// to post `contactsWereAdded` after the transaction commits.
    fileprivate static func upsert(
        db: Database,
        inboxId: String,
        addedViaConversationId: String?,
        profile: ContactProfileSnapshot
    ) throws -> Bool {
        if let existing = try DBContact.fetchOne(db, key: inboxId) {
            // Identity columns (addedAt, addedViaConversationId) are
            // intentionally preserved on re-upsert. The profile snapshot is
            // applied only if it carries a `profileUpdatedAt` newer than
            // the stored one (see `replacingProfile`); untimestamped
            // re-upserts leave the existing row untouched.
            guard let merged = replacingProfile(of: existing, with: profile) else {
                return false
            }
            try merged.save(db)
            return false
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
            agentVerification: profile.agentVerification
        )
        try row.save(db)
        Log.debug("Inserted new contact for inboxId=\(inboxId) via=\(addedViaConversationId ?? "nil")")
        return true
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
    /// In-transaction upsert that returns `true` when a brand-new contact
    /// row was inserted. Batch callers (e.g. `ContactSyncCoordinator`)
    /// accumulate the inserted inboxIds inside their `databaseWriter.write`
    /// closure and call `postContactsWereAdded(inboxIds:)` once after the
    /// transaction commits, so a single sweep covers the whole batch.
    @discardableResult
    static func upsertContactInTransaction(
        db: Database,
        inboxId: String,
        addedViaConversationId: String?,
        profile: ContactProfileSnapshot
    ) throws -> Bool {
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
        agentVerification: AgentVerification? = nil
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
            agentVerification: agentVerification
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
            agentVerification: profile.memberKind?.agentVerification
        )
    }
}
