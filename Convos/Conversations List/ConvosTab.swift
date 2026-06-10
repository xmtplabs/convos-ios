import SwiftUI

/// Source of truth for which lane of the main shell is active. Used as the
/// `selection` of the standard SwiftUI `TabView` that renders the system
/// tab bar for Convos, Things, and Contacts.
enum ConvosTab: Hashable {
    case chats
    case things
    case contacts

    var title: String {
        switch self {
        case .chats: "Convos"
        case .things: "Things"
        case .contacts: "Contacts"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "message.fill"
        case .things: "square.grid.2x2.fill"
        case .contacts: "person.fill"
        }
    }
}
