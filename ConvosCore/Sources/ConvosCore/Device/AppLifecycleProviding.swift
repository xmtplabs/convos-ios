import Foundation

/// Represents the current state of the application
public enum AppState: Sendable {
    case active
    case inactive
    case background
}

/// Protocol for observing app lifecycle events across platforms.
///
/// Implementations are platform-specific (iOS uses UIApplication notifications).
/// The protocol allows ConvosCore to respond to app lifecycle changes without UIKit dependencies.
public protocol AppLifecycleProviding: Sendable {
    /// Notification name posted when the app enters the background
    var didEnterBackgroundNotification: Notification.Name { get }

    /// Notification name posted when the app will enter the foreground
    var willEnterForegroundNotification: Notification.Name { get }

    /// Notification name posted when the app becomes active
    var didBecomeActiveNotification: Notification.Name { get }

    /// Returns the current application state
    @MainActor
    var currentState: AppState { get }
}
