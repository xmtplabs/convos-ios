import Foundation

/// Which entry point is showing `AgentsHomeView`. The screen is the same in
/// both; only the chrome differs, because the two hosts own the top of the
/// screen differently.
///
/// Mirrors the pattern `ContactCardMode` and `ContactsPickerMode` use for
/// their multi-entry-point surfaces.
enum AgentsHomeMode {
    /// The Agents tab. The shell's `AppIndicatorPill` owns the top-leading
    /// zone, so the screen sets no navigation title, exactly like the Convos
    /// and Contacts tab roots.
    case tabRoot
    /// Pushed from the App Settings "Agents" row, inside the settings sheet's
    /// own navigation stack, where an inline title is what the user expects
    /// from every other settings sub-page.
    case settingsPage

    var showsNavigationTitle: Bool {
        switch self {
        case .tabRoot: false
        case .settingsPage: true
        }
    }
}
