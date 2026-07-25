#if canImport(UIKit)
import Foundation

public extension Notification.Name {
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
#endif
