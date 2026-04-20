import Foundation

/// Account identifiers for specific keychain items
enum KeychainAccount {
    /// Account for storing JWT tokens, keyed by device ID
    static func jwt(deviceId: String) -> String {
        return deviceId
    }
}
