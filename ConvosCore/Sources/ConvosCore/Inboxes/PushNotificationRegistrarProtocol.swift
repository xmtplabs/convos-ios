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
/// PushNotificationRegistrar.configure(IOSPushNotificationRegistrar())
/// ```
public enum PushNotificationRegistrar {
    private static let lock: NSLock = .init()
    nonisolated(unsafe) private static var _shared: (any PushNotificationRegistrarProtocol)?
    nonisolated(unsafe) private static var isConfigured: Bool = false

    /// Configures the shared push notification registrar instance.
    /// - Important: Must be called exactly once during app initialization before use.
    /// - Parameter registrar: The platform-specific push notification registrar.
    public static func configure(_ registrar: any PushNotificationRegistrarProtocol) {
        lock.lock()
        defer { lock.unlock() }

        guard !isConfigured else {
            Log.error("PushNotificationRegistrar.configure() must only be called once")
            return
        }

        _shared = registrar
        isConfigured = true
    }

    /// The shared push notification registrar instance.
    /// - Important: `configure(_:)` must be called during app initialization before use.
    public static var shared: any PushNotificationRegistrarProtocol {
        lock.lock()
        defer { lock.unlock() }

        guard let registrar = _shared else {
            fatalError("PushNotificationRegistrar.configure() must be called before use")
        }
        return registrar
    }

    /// Returns the current push token, if available.
    /// Convenience accessor for `PushNotificationRegistrar.shared.token`
    public static var token: String? {
        lock.lock()
        defer { lock.unlock() }
        return _shared?.token
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

    /// Resets the configuration state. Only for use in tests.
    /// - Important: This is not thread-safe and should only be called from test setup.
    public static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        _shared = nil
        isConfigured = false
    }
}
