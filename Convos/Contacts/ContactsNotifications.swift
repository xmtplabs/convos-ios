import Foundation

extension Notification.Name {
    /// Posted by the contacts picker confirm path (ContactsView / ContactCardView)
    /// when the user picks contacts and asks to start a conversation with them.
    /// Carries `["inboxIds": [String]]` in `userInfo`.
    ///
    /// `ConversationsViewModel` listens for this and presents a
    /// `NewConversationView` driven by
    /// `NewConversationViewModel(mode: .newConversationWithMembers(...))`.
    /// The picker doesn't construct the new conversation itself, it just
    /// asks the conversations layer to route the user in. This keeps the
    /// placeholder-VM / state-machine flow identical to the "+" button.
    static let contactsRequestedNewConversation: Notification.Name = Notification.Name(
        "ContactsRequestedNewConversation"
    )

    /// Posted by surfaces inside an active chat (e.g. the "Add from Contacts"
    /// row in `NewConvoIdentityView`'s invite-members menu) to ask the
    /// containing `ConversationView` to present its contacts picker. Avoids
    /// plumbing a callback through ~9 layers of Messages / cell-factory /
    /// representable scaffolding for a single menu row. Carries no userInfo;
    /// the receiver already has the conversation context.
    static let requestAddFromContactsInCurrentConversation: Notification.Name = Notification.Name(
        "RequestAddFromContactsInCurrentConversation"
    )
}
