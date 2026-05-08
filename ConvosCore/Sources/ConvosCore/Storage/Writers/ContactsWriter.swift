import Foundation
import GRDB

public extension Notification.Name {
    /// Posted on the main queue by `ContactsWriter.block` / `unblock` when
    /// a contact's blocked state actually changes (idempotent no-ops do
    /// not fire). `SessionManager` observes this to run an immediate
    /// `QuarantineSweeper.sweep()` — unblocking should restore held-by-
    /// block conversations to the main feed without waiting for the next
    /// hourly or foreground-entry sweep. UserInfo:
    /// `inboxId: String`, `blocked: Bool`.
    static let contactBlockingDidChange: Notification.Name = Notification.Name(
        "ContactBlockingDidChange"
    )
}

/// Snapshot of profile fields used when upserting a contact. All fields are
/// optional — callers pass whatever they currently have for the inbox. A
/// `nil` field means "no signal — preserve whatever is already stored on the
/// contact." This supports partial updates: a profile event that carries
/// only an avatar URL won't clobber a stored display name, and a profile
/// event from a non-agent member won't unset a previously-observed
/// `agentVerification`.
public struct ContactProfileSnapshot: Sendable, Hashable {
    public let displayName: String?
    public let avatarURL: String?
    public let bio: String?
    public let profileUpdatedAt: Date?
    public let agentVerification: AgentVerification?

    public init(
        displayName: String? = nil,
        avatarURL: String? = nil,
        bio: String? = nil,
        profileUpdatedAt: Date? = nil,
        agentVerification: AgentVerification? = nil
    ) {
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.bio = bio
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
    /// is nil). Falls back to local now when the source has no timestamp so
    /// callers can still seed initial profile data.
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
            let merged = Self.mergeProfile(into: existing, with: profile)
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

    fileprivate static func upsert(
        db: Database,
        inboxId: String,
        addedViaConversationId: String?,
        profile: ContactProfileSnapshot
    ) throws {
        if let existing = try DBContact.fetchOne(db, key: inboxId) {
            // Identity columns (addedAt, addedViaConversationId) are
            // intentionally preserved on re-upsert.
            let merged = mergeProfile(into: existing, with: profile)
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
            bio: profile.bio,
            profileUpdatedAt: profile.profileUpdatedAt ?? now,
            agentVerification: profile.agentVerification
        )
        try row.save(db)
        Log.debug("Inserted new contact for inboxId=\(inboxId) via=\(addedViaConversationId ?? "nil")")
    }

    private static func mergeProfile(
        into existing: DBContact,
        with profile: ContactProfileSnapshot
    ) -> DBContact {
        // A snapshot without a `profileUpdatedAt` is "fill in defaults" data
        // — typically from `ContactSyncCoordinator`, which reads a per-
        // conversation `DBMemberProfile` that itself isn't timestamped. The
        // per-conversation profile may be stale relative to the contact's
        // most-recent-wins state (e.g., the local user knows the contact as
        // "Bob" from a recent ProfileUpdate in conversation A, but conv B's
        // older snapshot still says "Robert"). For untimestamped snapshots
        // we only populate fields the existing contact has nil/empty for —
        // we never overwrite known data with snapshots of unknown freshness.
        guard let incomingTimestamp = profile.profileUpdatedAt else {
            return existing.with(
                displayName: nonEmpty(existing.displayName) ?? profile.displayName,
                avatarURL: nonEmpty(existing.avatarURL) ?? profile.avatarURL,
                bio: nonEmpty(existing.bio) ?? profile.bio,
                profileUpdatedAt: existing.profileUpdatedAt,
                agentVerification: existing.agentVerification ?? profile.agentVerification
            )
        }

        // Timestamped snapshot — most-recent-wins.
        let storedTimestamp: Date? = existing.profileUpdatedAt
        let shouldApply: Bool
        if let storedTimestamp {
            shouldApply = incomingTimestamp >= storedTimestamp
        } else {
            shouldApply = true
        }
        guard shouldApply else { return existing }

        // We only overwrite a stored field if the incoming value is non-nil.
        // This lets profile snapshots that carry only some fields (e.g. just
        // an avatar update) merge cleanly without clobbering the others.
        // For agentVerification, the same rule preserves "last-known agent
        // state" — an incoming non-agent profile event (nil agentVerification)
        // does not clear a previously observed verification.
        let mergedName = profile.displayName ?? existing.displayName
        let mergedAvatar = profile.avatarURL ?? existing.avatarURL
        let mergedBio = profile.bio ?? existing.bio
        let mergedAgent = profile.agentVerification ?? existing.agentVerification
        return existing.with(
            displayName: mergedName,
            avatarURL: mergedAvatar,
            bio: mergedBio,
            profileUpdatedAt: incomingTimestamp,
            agentVerification: mergedAgent
        )
    }

    /// Helper for the fill-defaults branch of `mergeProfile`. Returns the
    /// string only when it's non-nil and non-empty, so callers can express
    /// "use stored if present, else fall back to incoming" with `??`.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
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

    /// Copies member-profile display fields onto the matching contact row inside an
    /// existing transaction (most-recent-wins via `mergeProfile`). No-ops when there is
    /// no contact for `inboxId` — profile events never auto-add contacts; only the
    /// action-gated coordinator does. An incoming `receivedAt` older than stored
    /// `profileUpdatedAt` is dropped.
    /// - Parameter agentVerification: pass when the calling site already
    ///   knows the verification state (e.g. it just resolved an attestation).
    ///   Pass `nil` to leave any previously stored verification untouched —
    ///   profile events from non-agent contexts should not clear a contact's
    ///   prior verified-agent flag.
    static func mirrorMemberProfileToContactInTransaction(
        db: Database,
        inboxId: String,
        name: String?,
        avatarURL: String?,
        receivedAt: Date,
        agentVerification: AgentVerification? = nil
    ) throws {
        guard let existing = try DBContact.fetchOne(db, key: inboxId) else {
            return
        }
        let snapshot = ContactProfileSnapshot(
            displayName: name,
            avatarURL: avatarURL,
            bio: nil,
            profileUpdatedAt: receivedAt,
            agentVerification: agentVerification
        )
        let merged = mergeProfile(into: existing, with: snapshot)
        try merged.save(db)
    }

    /// Persists `profile` and mirrors name/avatar onto the matching `DBContact` in the
    /// same transaction. Prefer this over `profile.save(db)` plus a separate mirror call
    /// so callers cannot skip the contact-list sync.
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
            receivedAt: receivedAt,
            agentVerification: profile.memberKind?.agentVerification
        )
    }
}
