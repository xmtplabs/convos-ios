import CoreGraphics
import Foundation

/// Which entry point is showing `AgentsHomeView`. The screen is the same in
/// both; only the inset at the top differs, because the two hosts own that
/// zone differently.
///
/// Mirrors the pattern `ContactCardMode` and `ContactsPickerMode` use for
/// their multi-entry-point surfaces.
enum AgentsHomeMode {
    /// The Agents tab. The shell's `AppIndicatorPill` owns the top-leading
    /// zone, exactly as it does on the Convos and Contacts tab roots.
    case tabRoot
    /// Pushed from the App Settings "Agents" row, inside the settings sheet's
    /// own navigation stack.
    case settingsPage

    /// Neither host sets a navigation title: the screen carries its own, the
    /// way Connections and Abilities do in the same settings sheet. The tab
    /// root only needs a little more room, because its content scrolls under
    /// the app-indicator pill, which hangs below the bar it shares the zone
    /// with.
    var topPadding: CGFloat {
        switch self {
        case .tabRoot: DesignConstants.Spacing.step3x
        case .settingsPage: DesignConstants.Spacing.step2x
        }
    }
}
