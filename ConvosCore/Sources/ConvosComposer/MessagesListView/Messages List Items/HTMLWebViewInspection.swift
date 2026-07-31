#if canImport(UIKit)
import ConvosCore
import WebKit

public extension WKWebView {
    /// Opts the WebView into Safari's Web Inspector outside production.
    ///
    /// Since iOS 16.4 the inspector refuses to attach unless the WebView
    /// sets `isInspectable`, so without this the agent-authored HTML we
    /// render has no console, no DOM tree, and no network panel - a broken
    /// artifact just paints blank. Production stays closed so a shipped
    /// build never exposes its render tree to a paired Mac.
    ///
    /// Gated at runtime rather than behind `#if DEBUG`: the flag does not
    /// propagate into SPM packages, so a compile-time check here would be
    /// dead in every build of this module.
    func enableInspectionOutsideProduction() {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
        isInspectable = true
    }
}
#endif
