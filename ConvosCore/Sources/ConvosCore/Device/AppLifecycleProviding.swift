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

// MARK: - Shared Instance Access

/// Accessor for the shared app lifecycle provider instance.
///
/// The concrete implementation must be set by the platform-specific layer (e.g., ConvosCoreiOS)
/// during app initialization before any code in ConvosCore accesses it.
///
/// Example usage in AppDelegate or App init:
/// ```swift
/// AppLifecycle.shared = IOSAppLifecycleProvider()
/// ```
public enum AppLifecycle {
    // Using nonisolated(unsafe) because:
    // 1. This is set once at app startup before any concurrent access
    // 2. After initialization, it's read-only
    // 3. The underlying type is Sendable
    nonisolated(unsafe) private static var _shared: (any AppLifecycleProviding)?

    /// The shared app lifecycle provider instance.
    /// - Important: Must be set during app initialization before use.
    public static var shared: any AppLifecycleProviding {
        get {
            guard let provider = _shared else {
                fatalError("AppLifecycle.shared must be set before use")
            }
            return provider
        }
        set {
            _shared = newValue
        }
    }

    /// Notification name posted when the app enters the background
    public static var didEnterBackgroundNotification: Notification.Name {
        shared.didEnterBackgroundNotification
    }

    /// Notification name posted when the app will enter the foreground
    public static var willEnterForegroundNotification: Notification.Name {
        shared.willEnterForegroundNotification
    }

    /// Notification name posted when the app becomes active
    public static var didBecomeActiveNotification: Notification.Name {
        shared.didBecomeActiveNotification
    }

    /// Returns the current application state
    @MainActor
    public static var currentState: AppState {
        shared.currentState
    }
}
