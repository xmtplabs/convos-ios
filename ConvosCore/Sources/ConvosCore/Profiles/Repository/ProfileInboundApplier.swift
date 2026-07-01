import Foundation
import GRDB

/// Writes one inbound profile event into the canonical `profile` / `profileAvatar`
/// tables, synchronously and inside an existing write transaction. This is the
/// cutover replacement for the legacy `DBMemberProfile` writes; every inbound
/// site (foreground stream, NSE extension, history catch-up) calls it inside its
/// own `databaseWriter.write { db in ... }` so the identity write shares the
/// message's transaction.
///
/// The merge itself reuses `ProfileMerge` (precedence + recency + tri-state
/// avatar), so behaviour matches `ProfilesRepository.apply`. Agent attestation is
/// preserved exactly: a transient, never-saved `DBMemberProfile` probe is
/// hydrated and verified as before, and the resolved `memberKind` flows into the
/// canonical identity and the `hasHadVerifiedAgent` marking. The current user's
/// own inbox is skipped - self identity is authored locally via `publishMyProfile`
/// / `selfProfile`, not received.
enum ProfileInboundApplier {
    /// How an inbound message addresses the avatar slot. A `ProfileUpdate`
    /// addresses it (absent image means "cleared"); a `ProfileSnapshot` or a
    /// history replay only fills it (absent image leaves the slot untouched).
    enum AvatarDisposition {
        case addressed(EncryptedProfileImageRef?)
        case fillIfPresent(EncryptedProfileImageRef?)
    }

    /// One inbound identity + avatar event for a member, before merge. Bundled so
    /// the seam's call sites (and `apply`) stay under the parameter-count limit.
    struct Incoming {
        let inboxId: String
        let source: ProfileSource
        let name: String?
        let avatar: AvatarDisposition
        let memberKind: DBMemberKind?
        let metadata: ProfileMetadata?
        let receivedAt: Date
    }

    static func apply(
        db: Database,
        conversationId: String,
        event: Incoming,
        selfInboxId: String?,
        fallbackEncryptionKey: Data?
    ) throws {
        let inboxId = event.inboxId
        guard !inboxId.isEmpty else { return }
        try DBMember(inboxId: inboxId).save(db)

        let existingProfile = try DBProfile.fetchOne(db, inboxId: inboxId)
        let resolvedKind = resolvedMemberKind(
            incomingKind: event.memberKind,
            name: event.name,
            metadata: event.metadata,
            priorKind: existingProfile?.memberKind,
            inboxId: inboxId,
            conversationId: conversationId
        )
        try markConversationHasVerifiedAgentIfNeeded(memberKind: resolvedKind, conversationId: conversationId, db: db)

        // Self identity is authored locally; skip inbound self echoes for the
        // canonical profile/avatar (matches ProfilesRepository.apply).
        if let selfInboxId, inboxId == selfInboxId { return }

        let mergedProfile = ProfileMerge.mergeIdentity(
            existing: existingProfile,
            inboxId: inboxId,
            incoming: IncomingIdentity(name: event.name, memberKind: resolvedKind, metadata: event.metadata),
            source: event.source,
            sentAt: event.receivedAt
        )
        if mergedProfile != existingProfile {
            try mergedProfile.save(db)
        }

        let existingAvatar = try DBProfileAvatar.fetchOne(db, inboxId: inboxId, conversationId: conversationId)
        let incomingAvatar = avatarEvent(event.avatar, existingKey: existingAvatar?.encryptionKey, fallbackKey: fallbackEncryptionKey)
        let mergedAvatar = ProfileMerge.mergeAvatar(
            existing: existingAvatar,
            inboxId: inboxId,
            conversationId: conversationId,
            incoming: incomingAvatar,
            source: event.source,
            sentAt: event.receivedAt
        )
        if let mergedAvatar, mergedAvatar != existingAvatar {
            try mergedAvatar.save(db)
        }
    }

    private static func avatarEvent(_ disposition: AvatarDisposition, existingKey: Data?, fallbackKey: Data?) -> IncomingAvatar {
        switch disposition {
        case let .addressed(image):
            guard let image, image.isValid else { return .explicitClear }
            return .set(url: image.url, salt: image.salt, nonce: image.nonce, key: existingKey ?? fallbackKey)
        case let .fillIfPresent(image):
            guard let image, image.isValid else { return .silent }
            return .set(url: image.url, salt: image.salt, nonce: image.nonce, key: existingKey ?? fallbackKey)
        }
    }

    /// Resolves the stored `memberKind`, preserving the legacy agent-attestation
    /// behaviour: verify a cached attestation for agents (which can upgrade the
    /// kind), and never downgrade a previously verified kind. Uses a transient
    /// `DBMemberProfile` (never saved) so the verification path is identical to
    /// the pre-cutover writer.
    private static func resolvedMemberKind(
        incomingKind: DBMemberKind?,
        name: String?,
        metadata: ProfileMetadata?,
        priorKind: DBMemberKind?,
        inboxId: String,
        conversationId: String
    ) -> DBMemberKind? {
        var probe = DBMemberProfile(conversationId: conversationId, inboxId: inboxId, name: name, avatar: nil)
        probe = probe.with(memberKind: incomingKind)
        if let metadata {
            probe = probe.with(metadata: metadata)
        }
        if probe.isAgent {
            let verification = probe.hydrateProfile().verifyCachedAgentAttestation()
            if verification.isVerified {
                probe = probe.with(memberKind: DBMemberKind.from(agentVerification: verification))
            }
        }
        if let priorKind, priorKind.agentVerification.isVerified, !probe.agentVerification.isVerified {
            probe = probe.with(memberKind: priorKind)
        }
        return probe.memberKind
    }

    private static func markConversationHasVerifiedAgentIfNeeded(
        memberKind: DBMemberKind?,
        conversationId: String,
        db: Database
    ) throws {
        guard memberKind?.agentVerification.isConvosAgent == true,
              let conversation = try DBConversation.fetchOne(db, id: conversationId),
              !conversation.hasHadVerifiedAgent else { return }
        try conversation.with(hasHadVerifiedAgent: true).save(db)
    }
}
