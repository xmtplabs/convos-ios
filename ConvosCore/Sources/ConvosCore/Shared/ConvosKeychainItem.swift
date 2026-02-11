import Foundation

/// Account identifiers for specific keychain items
enum KeychainAccount {
    /// Account for storing JWT tokens, keyed by device ID
    static func jwt(deviceId: String) -> String {
        return deviceId
    }

    /// Account for storing the unused inbox ID
    static let unusedInbox: String = "unused-inbox"

    /// Account for storing the unused conversation ID
    static let unusedConversation: String = "unused-conversation"
}
