import ConvosCore
import Foundation

/// Drives the section visibility on `ContactDetailView` based on where the
/// detail view was opened from. Mirrors `ContactsPickerMode`'s "one view,
/// multiple entry points" pattern - see `ContactsPickerMode` for a similar
/// example and `CLAUDE.md`'s "View Modes for Multi-Entry-Point Surfaces"
/// section for the convention.
///
/// Entry-point mapping:
/// - **`.standalone`**: opened from the contacts list. Surfaces the
///   identity sections (avatar / name), agent links when the contact
///   is a verified agent, "Chat", and Block / Unblock. Subtitle is
///   "Added X ago" sourced from `contact.addedAt`.
/// - **`.scopedToConversation(...)`**: opened from a member-avatar tap
///   inside a chat. Renders all standalone sections plus "Remove from
///   convo" (admin-only). Subtitle becomes "Invited X ago by Y" when
///   the member carries `joinedAt` / `invitedBy`.
///
/// Agent state is not a mode parameter; the detail view reads
/// `contact.agentVerification` directly. This keeps the verified-agent rows
/// consistent across both entry points.
enum ContactDetailMode: Hashable {
    case standalone
    case scopedToConversation(
        conversationId: String,
        canRemoveMembers: Bool,
        isCurrentUser: Bool,
        invitedBy: Profile?,
        joinedAt: Date?
    )

    var isScopedToConversation: Bool {
        if case .scopedToConversation = self { return true }
        return false
    }

    var conversationId: String? {
        if case .scopedToConversation(let id, _, _, _, _) = self { return id }
        return nil
    }

    var canRemoveMembers: Bool {
        if case .scopedToConversation(_, let allowed, _, _, _) = self { return allowed }
        return false
    }

    var isCurrentUser: Bool {
        if case .scopedToConversation(_, _, let isSelf, _, _) = self { return isSelf }
        return false
    }

    var invitedBy: Profile? {
        if case .scopedToConversation(_, _, _, let inviter, _) = self { return inviter }
        return nil
    }

    var joinedAt: Date? {
        if case .scopedToConversation(_, _, _, _, let joined) = self { return joined }
        return nil
    }
}
