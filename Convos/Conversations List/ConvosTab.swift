import SwiftUI

/// Source of truth for which lane of the main shell is active. Used both
/// as the `selection` of the underlying SwiftUI `TabView` (which we keep
/// purely for content + lifecycle management; the system tab bar is
/// hidden) and as the visual state for the custom `ConvosTabBar`.
enum ConvosTab: Hashable {
    case chats
    case stuff
    case search

    var title: String {
        switch self {
        case .chats: "Chats"
        case .stuff: "Stuff"
        case .search: "Search"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "message.fill"
        case .stuff: "square.grid.2x2.fill"
        case .search: "magnifyingglass"
        }
    }
}
