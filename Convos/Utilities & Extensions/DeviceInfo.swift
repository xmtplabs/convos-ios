import Foundation
import UIKit

/// Utility for accessing device information across the app
@MainActor
struct DeviceInfo {
    /// Returns the device's identifier for vendor (IDFV)
    /// This is a unique identifier that persists across app launches but resets when all apps from the same vendor are deleted
    static var identifierForVendor: String? {
        return UIDevice.current.identifierForVendor?.uuidString
    }

    /// Returns a fallback identifier if IDFV is not available
    /// This should rarely happen, but provides a backup solution
    static var fallbackIdentifier: String {
        // Generate a UUID and store it in UserDefaults as a fallback
        let key = "convos_fallback_device_id"
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }

        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    /// Returns the most appropriate device identifier
    /// Prefers IDFV but falls back to a persistent UUID if needed
    static var deviceIdentifier: String {
        return identifierForVendor ?? fallbackIdentifier
    }

    /// Returns the current OS string
    static var osString: String {
        #if targetEnvironment(macCatalyst)
        return "macos"
        #else
        return "ios"
        #endif
    }
}
