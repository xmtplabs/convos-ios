import Foundation

/// Presentation-layer model for a contact, hydrated from `DBContact`.
///
/// A contact is keyed by `inboxId` under the single-inbox identity model
/// (ADR-011). The display fields are a most-recent-wins snapshot of the
/// member-profile data the device has observed for that inbox.
public struct Contact: Hashable, Identifiable, Sendable {
    public var id: String { inboxId }

    public let inboxId: String
    public let displayName: String?
    public let avatarURL: String?
    /// Salt/nonce/key used to decrypt the encrypted avatar at `avatarURL`.
    /// Hydrated from `DBContact` which mirrors the latest `DBMemberProfile`
    /// encryption material via `mirrorMemberProfileToContactInTransaction`.
    /// `nil` means we have not observed encryption material for this contact
    /// yet; renderers should fall back to the monogram.
    public let avatarSalt: Data?
    public let avatarNonce: Data?
    public let avatarKey: Data?
    public let addedAt: Date
    public let addedViaConversationId: String?
    public let isBlocked: Bool
    /// Last-known agent verification for this contact. `nil` means we have
    /// not observed any agent signal for this inbox. The unified contact
    /// card surfaces verified-agent affordances (Get skills, Learn about
    /// agents) iff `agentVerification?.isVerified == true`.
    public let agentVerification: AgentVerification?
    /// The backend `AgentTemplate.id` a template-backed agent was
    /// provisioned from. `nil` for human contacts and for agents that do
    /// not carry a template. Persisted on `DBContact` (mirrored from the
    /// per-conversation member profile metadata) so it survives leaving
    /// every conversation with a running instance; `Contact.resolved(member:...)`
    /// overlays the freshest value when a live member profile is on hand.
    /// Drives the contact card's Chat action.
    public let agentTemplateId: String?
    /// The shareable web URL for a template-backed agent (the backend's
    /// `publishedUrl`). `nil` for human contacts and for agents that do
    /// not carry a template. Persisted on `DBContact` alongside
    /// `agentTemplateId`; overlaid live by `Contact.resolved(member:...)`
    /// when available. Drives the contact card's Share button.
    public let agentTemplatePublishedURL: String?
    /// Emoji glyph for the contact's avatar fallback. For template-backed
    /// agents this is persisted on `DBContact` (the template emoji) so the
    /// browse row renders it without a live member profile;
    /// `Contact.resolved(member:...)` overlays the freshest per-conversation
    /// emoji when available, matching `MessageAvatarView` in the messages list.
    public let profileEmoji: String?
    /// The agent runtime's `instanceId` for a specific provisioned agent.
    /// Not persisted on `DBContact`; overlaid at resolution time from the
    /// per-conversation member profile (see `Contact.resolved(member:...)`).
    public let agentInstanceId: String?
    /// The agent's published attestation signature, read from the
    /// per-conversation member profile metadata at resolution time. Not
    /// persisted on `DBContact`. Surfaced on the contact card behind a
    /// debug-build gate alongside `agentVerification` for diagnosing why an
    /// agent reads as verified or unverified. Overlaid via
    /// `with(agentAttestation:)`, applied last in `resolved(member:...)`.
    public let agentAttestation: String?

    public init(
        inboxId: String,
        displayName: String?,
        avatarURL: String?,
        avatarSalt: Data? = nil,
        avatarNonce: Data? = nil,
        avatarKey: Data? = nil,
        addedAt: Date,
        addedViaConversationId: String?,
        isBlocked: Bool = false,
        agentVerification: AgentVerification? = nil,
        agentTemplateId: String? = nil,
        agentTemplatePublishedURL: String? = nil,
        profileEmoji: String? = nil,
        agentInstanceId: String? = nil,
        agentAttestation: String? = nil
    ) {
        self.inboxId = inboxId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.avatarSalt = avatarSalt
        self.avatarNonce = avatarNonce
        self.avatarKey = avatarKey
        self.addedAt = addedAt
        self.addedViaConversationId = addedViaConversationId
        self.isBlocked = isBlocked
        self.agentVerification = agentVerification
        self.agentTemplateId = agentTemplateId
        self.agentTemplatePublishedURL = agentTemplatePublishedURL
        self.profileEmoji = profileEmoji
        self.agentInstanceId = agentInstanceId
        self.agentAttestation = agentAttestation
    }

    /// True when this contact has the full set of AES-256-GCM material
    /// needed to decrypt its avatar (32-byte salt, 12-byte nonce,
    /// 32-byte key). Mirrors `Profile.isAvatarEncrypted`. All three are
    /// required: the `ImageCacheable` conformance below sends `self` down
    /// the encrypted-fetch branch when this returns true, and
    /// `ImageCache.fetchEncryptedImageInline` silently returns `nil` if
    /// the key is missing.
    public var isAvatarEncrypted: Bool {
        avatarSalt?.count == 32 && avatarNonce?.count == 12 && avatarKey?.count == 32
    }

    /// True when this contact's last-known agent verification is a verified
    /// agent (Convos / OAuth attestation). Mirrors
    /// `ConversationMember.isVerifiedAgent` so both surfaces can hide
    /// verified-agent rows from human-facing contact browse / picker UI
    /// while keeping the DBContact row intact for chat-side rendering.
    public var isVerifiedAgent: Bool {
        agentVerification?.isVerified == true
    }

    /// True when we have any signal that this contact is an agent - any
    /// stored `agentVerification` (verified or unverified) or a known
    /// `agentTemplateId` from a template-backed provisioning. Used by
    /// `resolvedDisplayName` to swap the unnamed-contact placeholder from
    /// "Somebody" to "Agent" so the contact card doesn't read as a human
    /// when the agent badge or instance id is already on screen.
    public var isAgent: Bool {
        agentVerification != nil || agentTemplateId != nil
    }

    /// Display label that always returns something printable. Falls back
    /// to "Agent" for unnamed agent contacts (matches the role pill shown
    /// on the contact card) and "Somebody" otherwise -- exposing a hex
    /// inboxId prefix in any user-facing surface reads as a bug. Same
    /// placeholder convention the message-input and profile-settings
    /// surfaces use for unnamed participants.
    public var resolvedDisplayName: String {
        if let name = displayName, !name.isEmpty {
            return name
        }
        return isAgent ? "Agent" : "Somebody"
    }

    /// Used for alphabetical sectioning. Returns "#" for contacts whose
    /// resolved name does not begin with a letter. Always returns a
    /// single-character key; Unicode case mapping can expand one
    /// character into many ("ß".uppercased() == "SS"), and the list's
    /// section grouping contract requires a single key per row.
    public var alphabeticalSectionKey: String {
        guard let first = resolvedDisplayName.first else { return "#" }
        guard let firstUpper = String(first).uppercased().first, firstUpper.isLetter else {
            return "#"
        }
        return String(firstUpper)
    }
}

extension Contact {
    init(dbContact: DBContact) {
        self.init(
            inboxId: dbContact.inboxId,
            displayName: dbContact.displayName,
            avatarURL: dbContact.avatarURL,
            avatarSalt: dbContact.avatarSalt,
            avatarNonce: dbContact.avatarNonce,
            avatarKey: dbContact.avatarKey,
            addedAt: dbContact.addedAt,
            addedViaConversationId: dbContact.addedViaConversationId,
            isBlocked: dbContact.blockedAt != nil,
            agentVerification: dbContact.agentVerification,
            agentTemplateId: dbContact.agentTemplateId,
            agentTemplatePublishedURL: dbContact.agentTemplatePublishedURL,
            profileEmoji: dbContact.agentTemplateEmoji
        )
    }
}

extension Contact {
    public static func mock(
        inboxId: String = UUID().uuidString,
        displayName: String? = "Sample Contact",
        avatarURL: String? = nil,
        avatarSalt: Data? = nil,
        avatarNonce: Data? = nil,
        avatarKey: Data? = nil,
        addedViaConversationId: String? = nil,
        isBlocked: Bool = false,
        agentVerification: AgentVerification? = nil,
        agentTemplateId: String? = nil,
        agentTemplatePublishedURL: String? = nil,
        profileEmoji: String? = nil,
        agentInstanceId: String? = nil
    ) -> Contact {
        Contact(
            inboxId: inboxId,
            displayName: displayName,
            avatarURL: avatarURL,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce,
            avatarKey: avatarKey,
            addedAt: Date(),
            addedViaConversationId: addedViaConversationId,
            isBlocked: isBlocked,
            agentVerification: agentVerification,
            agentTemplateId: agentTemplateId,
            agentTemplatePublishedURL: agentTemplatePublishedURL,
            profileEmoji: profileEmoji,
            agentInstanceId: agentInstanceId
        )
    }

    /// Returns a copy with `agentTemplateId` overlaid. Used by
    /// `Contact.resolved(member:...)` to prefer the freshest template id
    /// from a live per-conversation member profile over the value
    /// persisted on the stored contact.
    public func with(agentTemplateId: String?) -> Contact {
        Contact(
            inboxId: inboxId,
            displayName: displayName,
            avatarURL: avatarURL,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce,
            avatarKey: avatarKey,
            addedAt: addedAt,
            addedViaConversationId: addedViaConversationId,
            isBlocked: isBlocked,
            agentVerification: agentVerification,
            agentTemplateId: agentTemplateId,
            agentTemplatePublishedURL: agentTemplatePublishedURL,
            profileEmoji: profileEmoji,
            agentInstanceId: agentInstanceId
        )
    }

    /// Returns a copy with `agentTemplatePublishedURL` overlaid. Used by
    /// `Contact.resolved(member:...)` to prefer the freshest template
    /// `publishedUrl` from a live per-conversation member profile over
    /// the value persisted on the stored contact.
    public func with(agentTemplatePublishedURL: String?) -> Contact {
        Contact(
            inboxId: inboxId,
            displayName: displayName,
            avatarURL: avatarURL,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce,
            avatarKey: avatarKey,
            addedAt: addedAt,
            addedViaConversationId: addedViaConversationId,
            isBlocked: isBlocked,
            agentVerification: agentVerification,
            agentTemplateId: agentTemplateId,
            agentTemplatePublishedURL: agentTemplatePublishedURL,
            profileEmoji: profileEmoji,
            agentInstanceId: agentInstanceId
        )
    }

    /// Returns a copy with `agentVerification` overlaid. Used by
    /// `Contact.resolved(member:...)` so the freshest verification
    /// (computed at runtime against the current keyset) wins over a
    /// stale stored value - e.g. a contact persisted before the agent
    /// attested would carry `nil` / `.unverified` until the next
    /// `mirrorMemberProfileToContactInTransaction` cycle, but the
    /// in-chat detail sheet should already render the verified chrome
    /// the moment the member surface considers them verified.
    public func with(agentVerification: AgentVerification?) -> Contact {
        Contact(
            inboxId: inboxId,
            displayName: displayName,
            avatarURL: avatarURL,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce,
            avatarKey: avatarKey,
            addedAt: addedAt,
            addedViaConversationId: addedViaConversationId,
            isBlocked: isBlocked,
            agentVerification: agentVerification,
            agentTemplateId: agentTemplateId,
            agentTemplatePublishedURL: agentTemplatePublishedURL,
            profileEmoji: profileEmoji,
            agentInstanceId: agentInstanceId
        )
    }

    /// Returns a copy with `profileEmoji` overlaid. Used by
    /// `Contact.resolved(member:...)` to prefer the freshest emoji glyph
    /// from a live per-conversation member profile over the value
    /// persisted on the stored contact.
    public func with(profileEmoji: String?) -> Contact {
        Contact(
            inboxId: inboxId,
            displayName: displayName,
            avatarURL: avatarURL,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce,
            avatarKey: avatarKey,
            addedAt: addedAt,
            addedViaConversationId: addedViaConversationId,
            isBlocked: isBlocked,
            agentVerification: agentVerification,
            agentTemplateId: agentTemplateId,
            agentTemplatePublishedURL: agentTemplatePublishedURL,
            profileEmoji: profileEmoji,
            agentInstanceId: agentInstanceId
        )
    }

    /// Returns a copy with `agentInstanceId` overlaid.
    public func with(agentInstanceId: String?) -> Contact {
        Contact(
            inboxId: inboxId,
            displayName: displayName,
            avatarURL: avatarURL,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce,
            avatarKey: avatarKey,
            addedAt: addedAt,
            addedViaConversationId: addedViaConversationId,
            isBlocked: isBlocked,
            agentVerification: agentVerification,
            agentTemplateId: agentTemplateId,
            agentTemplatePublishedURL: agentTemplatePublishedURL,
            profileEmoji: profileEmoji,
            agentInstanceId: agentInstanceId,
            agentAttestation: agentAttestation
        )
    }

    /// Returns a copy with `agentAttestation` overlaid. The other `with(...)`
    /// overlays don't carry this field, so apply this one last in
    /// `resolved(member:...)` -- it copies every current field, so any prior
    /// overlay in the chain is preserved.
    public func with(agentAttestation: String?) -> Contact {
        Contact(
            inboxId: inboxId,
            displayName: displayName,
            avatarURL: avatarURL,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce,
            avatarKey: avatarKey,
            addedAt: addedAt,
            addedViaConversationId: addedViaConversationId,
            isBlocked: isBlocked,
            agentVerification: agentVerification,
            agentTemplateId: agentTemplateId,
            agentTemplatePublishedURL: agentTemplatePublishedURL,
            profileEmoji: profileEmoji,
            agentInstanceId: agentInstanceId,
            agentAttestation: agentAttestation
        )
    }
}

extension Contact: ImageCacheable {
    /// Inbox-scoped cache key, distinct from `Profile.imageCacheIdentifier`
    /// (which is conversation-scoped) so the global contact-default and
    /// per-conversation profile snapshots don't share a cache entry.
    public var imageCacheIdentifier: String {
        "contact:\(inboxId)"
    }

    public var imageCacheURL: URL? {
        avatarURL.flatMap { URL(string: $0) }
    }

    public var isEncryptedImage: Bool {
        isAvatarEncrypted
    }

    public var encryptionKey: Data? {
        avatarKey
    }

    public var encryptionSalt: Data? {
        avatarSalt
    }

    public var encryptionNonce: Data? {
        avatarNonce
    }
}
