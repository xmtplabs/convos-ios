import Foundation
import SwiftProtobuf

// MARK: - InvitePayload Extensions

extension InvitePayload {
    /// Creator's inbox ID converted from raw bytes to hex string
    public var creatorInboxIdString: String {
        creatorInboxID.toHexString()
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

// MARK: - SignedInvite Accessors

extension SignedInvite {
    /// Deserialized payload for accessing invite data
    /// The stored `payload` property is `Data` to preserve the exact bytes that were signed.
    public var invitePayload: InvitePayload {
        do {
            return try InvitePayload(serializedBytes: self.payload)
        } catch {
            return InvitePayload()
        }
    }

    public var expiresAt: Date? {
        invitePayload.expiresAtUnixIfPresent
    }

    public var hasExpired: Bool {
        guard let expiresAt else { return false }
        return Date() > expiresAt
    }

    public var conversationHasExpired: Bool {
        guard let conversationExpiresAt else { return false }
        return Date() > conversationExpiresAt
    }

    public var name: String? {
        invitePayload.nameIfPresent
    }

    public var inviteDescription: String? {
        invitePayload.descriptionIfPresent
    }

    /// Alias for backward compatibility with protobuf naming
    public var description_p: String? {
        inviteDescription
    }

    public var imageURL: String? {
        invitePayload.imageURLIfPresent
    }

    public var conversationExpiresAt: Date? {
        invitePayload.conversationExpiresAtUnixIfPresent
    }

    public var expiresAfterUse: Bool {
        invitePayload.expiresAfterUse
    }

    /// Set the payload from an InvitePayload
    public mutating func setPayload(_ payload: InvitePayload) throws {
        self.payload = try payload.serializedData()
    }
}
