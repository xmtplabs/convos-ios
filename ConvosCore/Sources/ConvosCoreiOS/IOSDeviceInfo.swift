#if canImport(UIKit)
import ConvosCore
import Foundation
import UIKit

/// iOS implementation of device information provider.
///
/// Uses UIDevice for vendor identifier and provides iOS-specific OS string.
/// Must be initialized on the main thread to capture main actor-isolated UIDevice properties.
@MainActor
public final class IOSDeviceInfo: DeviceInfoProviding, @unchecked Sendable {
    private let _identifierForVendor: String?

    public init() {
        _identifierForVendor = UIDevice.current.identifierForVendor?.uuidString
    }

    /// Returns the device's identifier for vendor (IDFV).
    /// This is a unique identifier that persists across app launches but resets when all apps
    /// from the same vendor are deleted.
    public nonisolated var identifierForVendor: String? {
        _identifierForVendor
    }

    /// Returns a fallback identifier if IDFV is not available.
    /// This should rarely happen, but provides a backup solution.
    public nonisolated var fallbackIdentifier: String {
        // Generate a UUID and store it in UserDefaults as a fallback
        let key = "convos_fallback_device_id"
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }

        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    /// Returns the most appropriate device identifier.
    /// Prefers IDFV but falls back to a persistent UUID if needed.
    public nonisolated var deviceIdentifier: String {
        identifierForVendor ?? fallbackIdentifier
    }

    /// Returns the current OS string.
    public nonisolated var osString: String {
        #if targetEnvironment(macCatalyst)
        return "macos"
        #else
        return "ios"
        #endif
    }
}
#endif
