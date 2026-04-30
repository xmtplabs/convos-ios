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
    public let bio: String?
    public let addedAt: Date
    public let addedViaConversationId: String?

    public init(
        inboxId: String,
        displayName: String?,
        avatarURL: String?,
        bio: String?,
        addedAt: Date,
        addedViaConversationId: String?
    ) {
        self.inboxId = inboxId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.bio = bio
        self.addedAt = addedAt
        self.addedViaConversationId = addedViaConversationId
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
    /// resolved name does not begin with a letter.
    public var alphabeticalSectionKey: String {
        guard let first = resolvedDisplayName.first else { return "#" }
        let upper = String(first).uppercased()
        guard upper.first?.isLetter == true else { return "#" }
        return upper
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
            bio: dbContact.bio,
            addedAt: dbContact.addedAt,
            addedViaConversationId: dbContact.addedViaConversationId
        )
    }
}

extension Contact {
    public static func mock(
        inboxId: String = UUID().uuidString,
        displayName: String? = "Sample Contact",
        avatarURL: String? = nil,
        bio: String? = nil,
        addedViaConversationId: String? = nil
    ) -> Contact {
        Contact(
            inboxId: inboxId,
            displayName: displayName,
            avatarURL: avatarURL,
            bio: bio,
            addedAt: Date(),
            addedViaConversationId: addedViaConversationId
        )
    }
}
