#if canImport(UIKit)
import Foundation

/// Runtime context flags for the host embedding ConvosComposer.
///
/// App extensions must not call app-only API (`UIApplication.shared`) and
/// cannot afford the heavy render paths (the WKWebView prewarmer); extension
/// hosts set `isAppExtension` once at launch and the affected paths degrade
/// gracefully (skip prewarming, fall back to trait-based display scale,
/// no-op the in-app browser).
public enum ComposerHostContext {
    @MainActor public static var isAppExtension: Bool = false
}
#endif
