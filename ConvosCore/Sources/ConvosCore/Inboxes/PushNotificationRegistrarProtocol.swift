import Foundation

// MARK: - Protocol

/// Protocol for managing push notification token storage and authorization.
///
/// Implementations are platform-specific (iOS uses UIKit/UserNotifications).
/// The protocol allows ConvosCore to work with push tokens without UIKit dependencies.
public protocol PushNotificationRegistrarProtocol: Sendable {
    /// Returns the current push token, if available.
    var token: String? { get }

    /// Saves the push token and notifies observers of the change.
    /// Called by AppDelegate when APNS token is received.
    func save(token: String)

    /// Requests notification authorization if not already granted, then registers for remote notifications.
    /// Can be called from anywhere in the app when user takes an action that would benefit from notifications.
    /// - Returns: `true` if authorization was granted, `false` otherwise
    func requestNotificationAuthorizationIfNeeded() async -> Bool
}

// MARK: - Shared Instance Access

/// Accessor for the shared push notification registrar instance.
///
/// The concrete implementation must be set by the platform-specific layer (e.g., ConvosCoreiOS)
/// during app initialization before any code in ConvosCore accesses it.
///
/// Example usage in AppDelegate or App init:
/// ```swift
/// PushNotificationRegistrar.shared = IOSPushNotificationRegistrar()
/// ```
public enum PushNotificationRegistrar {
    // Using nonisolated(unsafe) because:
    // 1. This is set once at app startup before any concurrent access
    // 2. After initialization, it's read-only
    // 3. The underlying type is Sendable
    nonisolated(unsafe) private static var _shared: (any PushNotificationRegistrarProtocol)?

    /// The shared push notification registrar instance.
    /// - Important: Must be set during app initialization before use.
    public static var shared: any PushNotificationRegistrarProtocol {
        get {
            guard let registrar = _shared else {
                fatalError("PushNotificationRegistrar.shared must be set before use")
            }
            return registrar
        }
        set {
            _shared = newValue
        }
    }

    /// Returns the current push token, if available.
    /// Convenience accessor for `PushNotificationRegistrar.shared.token`
    public static var token: String? {
        _shared?.token
    }

    /// Saves the push token and notifies observers of the change.
    /// Convenience accessor for `PushNotificationRegistrar.shared.save(token:)`
    public static func save(token: String) {
        shared.save(token: token)
    }

    /// Requests notification authorization if not already granted, then registers for remote notifications.
    /// Convenience accessor for `PushNotificationRegistrar.shared.requestNotificationAuthorizationIfNeeded()`
    public static func requestNotificationAuthorizationIfNeeded() async -> Bool {
        await shared.requestNotificationAuthorizationIfNeeded()
    }
}
