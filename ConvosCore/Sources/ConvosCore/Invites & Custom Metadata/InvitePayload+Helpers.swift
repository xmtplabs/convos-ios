import Foundation
import SwiftProtobuf

// MARK: - InvitePayload + Helpers

extension InvitePayload {
    /// Creator's inbox ID converted from raw bytes to hex string
    public var creatorInboxIdString: String {
        creatorInboxID.hexEncodedString()
    }

    public var expiresAtUnixIfPresent: Date? {
        guard hasExpiresAtUnix else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(expiresAtUnix))
    }

    public var conversationExpiresAtUnixIfPresent: Date? {
        guard hasConversationExpiresAtUnix else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(conversationExpiresAtUnix))
    }

    public var nameIfPresent: String? {
        guard hasName else { return nil }
        return name
    }

    public var descriptionIfPresent: String? {
        guard hasDescription_p else { return nil }
        return description_p
    }

    public var imageURLIfPresent: String? {
        guard hasImageURL else { return nil }
        return imageURL
    }
}
