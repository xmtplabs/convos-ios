import ConvosCore
import SwiftUI

/// Mode discriminator for [[AdaptiveAppIndicator]]. Tells the indicator
/// whether to render the leading app-info pill (no conversation selected)
/// or the centered conversation pill (a conversation is in focus, including
/// draft states inside the AgentBuilder, NewConversationView, and the
/// ContactsPicker which all wrap the indicator around a draft VM).
enum AdaptiveAppIndicatorMode {
    /// No conversation in focus. Renders [[AppIndicatorPill]] at the leading
    /// edge of the top bar with the user's avatar + app-level title /
    /// subtitle. Tapping it opens app-level settings via the `onAppInfoTap`
    /// closure threaded through the presenter.
    case app(AppIndicatorContext)
    /// A conversation (or draft) is in focus. Renders the existing
    /// conversation pill in its centered position; matches today's
    /// behavior 1:1.
    case conversation
}

/// Subtitle for [[AppIndicatorPill]]. Either a plain string (typically the
/// active subscription tier name) or an SF Symbol — currently used to
/// surface depleted credit balance as a bolt icon in colorLava.
enum AppIndicatorSubtitle {
    case text(String)
    case symbol(systemName: String, tint: Color, accessibilityLabel: String)

    var accessibilityText: String {
        switch self {
        case .text(let value):
            return value
        case .symbol(_, _, let label):
            return label
        }
    }
}

/// Lightweight value type holding the bits the app-mode pill needs.
/// Pulled into its own struct so the [[AdaptiveAppIndicatorMode]] enum
/// doesn't have to enumerate every field at every callsite — the
/// presenter constructs this once from `ProfileSettingsViewModel.shared`.
///
/// `transitionNamespace` + `transitionId` together opt the pill into the
/// matched-geometry zoom transition used elsewhere in the app for top-bar
/// buttons (e.g. the compose -> `NewConversationView` zoom). When both are
/// set the presenter applies `.matchedTransitionSource(id:in:)` on the
/// pill and the presented sheet pairs `.navigationTransition(.zoom(...))`
/// with the same id to get the source-to-sheet morph.
struct AppIndicatorContext {
    let profileImage: UIImage?
    let title: String
    let subtitle: AppIndicatorSubtitle
    let onTap: () -> Void
    let transitionNamespace: Namespace.ID?
    let transitionId: String?
    /// Shared namespace for the AppIndicatorPill ↔ centered conversation
    /// indicator matched-geometry effect when the pill is rendered
    /// outside of `ConversationPresenter` (e.g. lifted to
    /// `MainTabView.sharedTopBar`). The per-tab presenter uses this
    /// for its conversation-indicator matched geometry so SwiftUI can
    /// morph between the two even though they live in different
    /// subtrees.
    let sharedIndicatorNamespace: Namespace.ID?

    init(
        profileImage: UIImage?,
        title: String = "Convos",
        subtitle: AppIndicatorSubtitle = .text("Free"),
        transitionNamespace: Namespace.ID? = nil,
        transitionId: String? = nil,
        sharedIndicatorNamespace: Namespace.ID? = nil,
        onTap: @escaping () -> Void = {}
    ) {
        self.profileImage = profileImage
        self.title = title
        self.subtitle = subtitle
        self.transitionNamespace = transitionNamespace
        self.transitionId = transitionId
        self.sharedIndicatorNamespace = sharedIndicatorNamespace
        self.onTap = onTap
    }
}
