#if canImport(UIKit)
import SwiftUI
import WebKit

/// Shared JS + CSS-color plumbing used by both `AttachmentHTMLContent`
/// (live sheet) and `HTMLContentPrewarmer` (off-screen warm-up). The
/// renderer for an agent's HTML page injects this script to report its
/// computed body background back to native, so the surrounding sheet
/// can tint its chrome to match the page tone. Keeping one source of
/// truth here means a future tweak to the JS or the parser only has
/// to land in one place.
public enum HTMLBodyBackgroundBridge {
    /// Name of the message handler the JS script posts to. Both sides
    /// register a `WKScriptMessageHandler` under this name on the
    /// `WKUserContentController`.
    public static let messageHandlerName: String = "convosBg"

    /// JS injected at `.atDocumentEnd` that reports the computed body
    /// background back to native via `window.webkit.messageHandlers`.
    /// Reports once at end-of-document and again on `load` so layouts
    /// that paint a background only after stylesheets resolve still
    /// land their final colour.
    static let userScriptSource: String = """
    (function() {
        function postBg() {
            var bg = getComputedStyle(document.body).backgroundColor;
            if (!bg || bg === 'rgba(0, 0, 0, 0)' || bg === 'transparent') {
                bg = getComputedStyle(document.documentElement).backgroundColor;
            }
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.convosBg) {
                window.webkit.messageHandlers.convosBg.postMessage(bg || '');
            }
        }
        postBg();
        window.addEventListener('load', postBg);
    })();
    """

    /// Build a `WKUserScript` that injects `userScriptSource` at document end.
    /// `WKUserScript.init` is main-actor isolated in iOS 26, so the helper
    /// is too; the only callers (the live sheet's `makeUIView` and the
    /// prewarmer) already run on the main actor.
    @MainActor
    public static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: userScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    /// Parses the `rgb(...)` / `rgba(...)` payload posted by the JS
    /// script. Returns nil for fully-transparent or unrecognised
    /// formats so the caller can fall back to its default tint.
    public static func parseCSSColor(_ raw: String) -> Color? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let isRGBA = trimmed.hasPrefix("rgba(")
        let prefix = isRGBA ? "rgba(" : "rgb("
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(")") else { return nil }
        let inner = trimmed.dropFirst(prefix.count).dropLast()
        let parts = inner
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3,
              let red = Double(parts[0]),
              let green = Double(parts[1]),
              let blue = Double(parts[2]) else { return nil }
        let alpha: Double = parts.count >= 4 ? (Double(parts[3]) ?? 1.0) : 1.0
        if alpha < 0.05 { return nil }
        return Color(.sRGB, red: red / 255.0, green: green / 255.0, blue: blue / 255.0, opacity: alpha)
    }
}
#endif
