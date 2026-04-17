import Foundation

/// Account identifiers for specific keychain items
enum KeychainAccount {
    /// Account for storing JWT tokens, keyed by device ID
    static func jwt(deviceId: String) -> String {
        return deviceId
    }

    /// Account for storing the pre-created unused conversation ID
    static let unusedConversation: String = "unused-conversation"
}
