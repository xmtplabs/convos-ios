import Foundation
import SwiftProtobuf

// MARK: - ConversationProfile + Helpers

extension ConversationProfile {
    /// InboxId as hex string (convenience accessor for bytes field)
    public var inboxIdString: String {
        inboxID.hexEncodedString()
    }

    /// Failable initializer with hex-encoded inbox ID string
    /// - Parameters:
    ///   - inboxIdString: Hex-encoded inbox ID (XMTP v3 format)
    ///   - name: Optional display name
    ///   - imageUrl: Optional avatar URL
    /// - Returns: ConversationProfile if inbox ID is valid hex, nil otherwise
    public init?(inboxIdString: String, name: String? = nil, imageUrl: String? = nil) {
        guard let inboxIdBytes = Data(hexString: inboxIdString), !inboxIdBytes.isEmpty else {
            return nil
        }

        self.init()
        self.inboxID = inboxIdBytes

        if let name = name {
            self.name = name
        } else {
            self.clearName()
        }
        if let imageUrl = imageUrl {
            self.image = imageUrl
        } else {
            self.clearImage()
        }
    }
}
