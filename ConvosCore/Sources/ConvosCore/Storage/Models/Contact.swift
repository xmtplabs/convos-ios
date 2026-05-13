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
        addedAt: Date,
        addedViaConversationId: String?,
        isBlocked: Bool = false,
        agentVerification: AgentVerification? = nil
    ) {
        self.inboxId = inboxId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.addedAt = addedAt
        self.addedViaConversationId = addedViaConversationId
        self.isBlocked = isBlocked
        self.agentVerification = agentVerification
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
        addedViaConversationId: String? = nil,
        isBlocked: Bool = false,
        agentVerification: AgentVerification? = nil
    ) -> Contact {
        Contact(
            inboxId: inboxId,
            displayName: displayName,
            avatarURL: avatarURL,
            addedAt: Date(),
            addedViaConversationId: addedViaConversationId,
            isBlocked: isBlocked,
            agentVerification: agentVerification
        )
    }
}
