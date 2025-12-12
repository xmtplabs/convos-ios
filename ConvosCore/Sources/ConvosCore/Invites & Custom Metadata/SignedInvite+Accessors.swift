import Foundation
import SwiftProtobuf

// MARK: - SignedInvite + Accessors

/// Extensions for accessing SignedInvite payload data
extension SignedInvite {
    /// Deserialized payload for accessing invite data
    /// The stored `payload` property is `Data` to preserve the exact bytes that were signed.
    /// This ensures signatures remain valid even if the protobuf schema changes.
    /// Use this property when you need to access fields like `.tag`, `.conversationToken`, etc.
    public var invitePayload: InvitePayload {
        do {
            return try InvitePayload(serializedBytes: self.payload)
        } catch {
            // If deserialization fails, return empty payload
            // This should not happen in normal operation
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

    public var description_p: String? {
        invitePayload.descriptionIfPresent
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
    /// This serializes the InvitePayload to bytes and stores them to preserve the exact bytes that were signed.
    public mutating func setPayload(_ payload: InvitePayload) throws {
        self.payload = try payload.serializedData()
    }
}
