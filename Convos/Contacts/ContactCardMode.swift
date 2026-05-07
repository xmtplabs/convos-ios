import Foundation

/// Drives the section visibility on `ContactCardView` based on where the
/// card was opened from. Mirrors `ContactsPickerMode`'s "one view, multiple
/// entry points" pattern — see `ContactsPickerMode` for a similar example
/// and `CLAUDE.md`'s "View Modes for Multi-Entry-Point Surfaces" section
/// for the convention.
///
/// Entry-point mapping:
/// - **`.standalone`** — card opened from the contacts list. Surfaces the
///   identity sections (avatar / name / bio), agent links when the contact
///   is a verified agent, "Send a message", and Block / Unblock.
/// - **`.scopedToConversation(...)`** — card opened from a member-avatar tap
///   inside a chat. Renders all standalone sections plus a "Group actions"
///   section: Remove from convo (admin-only) and Block-and-leave.
///
/// Agent state is *not* a mode parameter — the card reads
/// `contact.agentVerification` directly. This keeps the verified-agent rows
/// consistent across both entry points.
enum ContactCardMode: Hashable {
    case standalone
    case scopedToConversation(
        conversationId: String,
        canRemoveMembers: Bool,
        isCurrentUser: Bool
    )

    var isScopedToConversation: Bool {
        if case .scopedToConversation = self { return true }
        return false
    }

    var conversationId: String? {
        if case .scopedToConversation(let id, _, _) = self { return id }
        return nil
    }

    var canRemoveMembers: Bool {
        if case .scopedToConversation(_, let allowed, _) = self { return allowed }
        return false
    }

    var isCurrentUser: Bool {
        if case .scopedToConversation(_, _, let isSelf) = self { return isSelf }
        return false
    }
}
