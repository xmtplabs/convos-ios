import SwiftUI

/// Source of truth for which lane of the main shell is active. Used as the
/// `selection` of the standard SwiftUI `TabView` that renders the system
/// tab bar for Convos, Contacts and Agents.
///
/// `CaseIterable` on purpose: every enumeration site in the shell
/// (`MainTabView.navStateForTab`, the metrics dispatch, the tab builder)
/// switches exhaustively over this, so adding a lane surfaces as a compile
/// error at each place that has to decide what the new lane does.
enum ConvosTab: Hashable, CaseIterable {
    case chats
    case contacts
    case agents

    var title: String {
        switch self {
        case .chats: "Convos"
        case .contacts: "Contacts"
        case .agents: "Relay"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "message.fill"
        case .contacts: "person.crop.circle.fill"
        case .agents: "antenna.radiowaves.left.and.right"
        }
    }
}
