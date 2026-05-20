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
    /// assistants) iff `agentVerification?.isVerified == true`.
    public let agentVerification: AgentVerification?

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
        agentVerification: AgentVerification? = nil
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

    /// Display label that always returns something printable. Falls back to a
    /// truncated inboxId so the alphabetical browse list never renders an
    /// empty cell.
    public var resolvedDisplayName: String {
        if let name = displayName, !name.isEmpty {
            return name
        }
        return shortInboxId
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

    private var shortInboxId: String {
        guard inboxId.count > 8 else { return inboxId }
        return String(inboxId.prefix(8))
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
            agentVerification: dbContact.agentVerification
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
        agentVerification: AgentVerification? = nil
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
            agentVerification: agentVerification
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
