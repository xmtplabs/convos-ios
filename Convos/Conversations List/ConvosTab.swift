import SwiftUI

/// Source of truth for which lane of the main shell is active. Used as the
/// `selection` of the standard SwiftUI `TabView` that renders the system
/// tab bar for Chats, Things, and Contacts.
enum ConvosTab: Hashable {
    case chats
    case stuff
    case contacts

    var title: String {
        switch self {
        case .chats: "Chats"
        case .stuff: "Things"
        case .contacts: "Contacts"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "message.fill"
        case .stuff: "square.grid.2x2.fill"
        case .contacts: "person.fill"
        }
    }
}
