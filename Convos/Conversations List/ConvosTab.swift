import SwiftUI

/// Source of truth for which lane of the main shell is active. Used as the
/// `selection` of the standard SwiftUI `TabView` that renders the system
/// tab bar for Chats and Stuff.
///
/// Search was a third lane that is temporarily removed; reintroduce a
/// `.search` case here (and a `Tab` for it in `MainTabView`) to bring it
/// back.
enum ConvosTab: Hashable {
    case chats
    case stuff

    var title: String {
        switch self {
        case .chats: "Chats"
        case .stuff: "Stuff"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "message.fill"
        case .stuff: "square.grid.2x2.fill"
        }
    }
}
