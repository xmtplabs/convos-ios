import Foundation

/// Protocol for accessing device information across platforms.
///
/// Implementations are platform-specific (iOS uses UIDevice, macOS uses different APIs).
/// The protocol allows ConvosCore to work with device identifiers without UIKit dependencies.
public protocol DeviceInfoProviding: Sendable {
    /// Returns the device's identifier for vendor (IDFV) on iOS, or equivalent on other platforms.
    /// This is a unique identifier that persists across app launches but resets when all apps
    /// from the same vendor are deleted.
    var identifierForVendor: String? { get }

    /// Returns a fallback identifier if the vendor identifier is not available.
    /// This generates a UUID and stores it persistently as a backup solution.
    var fallbackIdentifier: String { get }

    /// Returns the most appropriate device identifier.
    /// Prefers vendor identifier but falls back to a persistent UUID if needed.
    var deviceIdentifier: String { get }

    /// Returns the current OS string (e.g., "ios", "macos").
    var osString: String { get }
}

// MARK: - Shared Instance Access

/// Accessor for the shared device info provider instance.
///
/// The concrete implementation must be set by the platform-specific layer (e.g., ConvosCoreiOS)
/// during app initialization before any code in ConvosCore accesses it.
///
/// Example usage in AppDelegate or App init:
/// ```swift
/// DeviceInfo.configure(IOSDeviceInfo())
/// ```
public enum DeviceInfo {
    private static let lock: NSLock = .init()
    nonisolated(unsafe) private static var _shared: (any DeviceInfoProviding)?
    nonisolated(unsafe) private static var isConfigured: Bool = false

    /// Configures the shared device info provider instance.
    /// - Important: Must be called exactly once during app initialization before use.
    /// - Parameter provider: The platform-specific device info provider.
    public static func configure(_ provider: any DeviceInfoProviding) {
        lock.lock()
        defer { lock.unlock() }

        guard !isConfigured else {
            Log.error("DeviceInfo.configure() must only be called once")
            return
        }

        _shared = provider
        isConfigured = true
    }

    /// The shared device info provider instance.
    /// - Important: `configure(_:)` must be called during app initialization before use.
    public static var shared: any DeviceInfoProviding {
        lock.lock()
        defer { lock.unlock() }

        guard let provider = _shared else {
            fatalError("DeviceInfo.configure() must be called before use")
        }
        return provider
    }

    /// Returns the most appropriate device identifier.
    /// Convenience accessor for `DeviceInfo.shared.deviceIdentifier`
    public static var deviceIdentifier: String {
        shared.deviceIdentifier
    }

    /// Returns the current OS string.
    /// Convenience accessor for `DeviceInfo.shared.osString`
    public static var osString: String {
        shared.osString
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
