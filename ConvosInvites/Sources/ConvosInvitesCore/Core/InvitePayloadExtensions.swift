import Foundation
import SwiftProtobuf

// MARK: - Invite Slug Creation

/// Options for creating an invite slug
public struct InviteSlugOptions: Sendable {
    public var name: String?
    public var description: String?
    public var imageURL: String?
    public var expiresAt: Date?
    public var expiresAfterUse: Bool
    public var conversationExpiresAt: Date?
    public var includePublicPreview: Bool

    public init(
        name: String? = nil,
        description: String? = nil,
        imageURL: String? = nil,
        expiresAt: Date? = nil,
        expiresAfterUse: Bool = false,
        conversationExpiresAt: Date? = nil,
        includePublicPreview: Bool = true
    ) {
        self.name = name
        self.description = description
        self.imageURL = imageURL
        self.expiresAt = expiresAt
        self.expiresAfterUse = expiresAfterUse
        self.conversationExpiresAt = conversationExpiresAt
        self.includePublicPreview = includePublicPreview
    }
}

extension SignedInvite {
    /// Create a signed, encoded invite slug from conversation parameters
    ///
    /// This is the primary API for creating invite URLs. It handles token encryption,
    /// payload construction, signing, and URL-safe encoding in a single call.
    ///
    /// - Parameters:
    ///   - conversationId: The XMTP conversation/group ID
    ///   - creatorInboxId: Hex-encoded inbox ID of the conversation creator
    ///   - privateKey: 32-byte secp256k1 private key for the creator's inbox
    ///   - tag: The invite tag for this conversation (used for verification and revocation)
    ///   - options: Optional configuration for public preview, expiration, etc.
    /// - Returns: URL-safe encoded invite slug
    public static func createSlug(
        conversationId: String,
        creatorInboxId: String,
        privateKey: Data,
        tag: String,
        options: InviteSlugOptions = InviteSlugOptions()
    ) throws -> String {
        guard !tag.isEmpty else {
            throw InviteTokenError.emptyInviteTag
        }

        let conversationTokenBytes = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: creatorInboxId,
            privateKey: privateKey
        )

        var payload = InvitePayload()
        payload.tag = tag
        payload.conversationToken = conversationTokenBytes
        payload.expiresAfterUse = options.expiresAfterUse

        guard let inboxIdBytes = Data(hexString: creatorInboxId), !inboxIdBytes.isEmpty else {
            throw InviteEncodingError.invalidBase64
        }
        payload.creatorInboxID = inboxIdBytes

        if options.includePublicPreview {
            if let name = options.name {
                payload.name = name
            }
            if let description = options.description {
                payload.description_p = description
            }
            if let imageURL = options.imageURL {
                payload.imageURL = imageURL
            }
        }

        if let expiresAt = options.expiresAt {
            payload.expiresAtUnix = Int64(expiresAt.timeIntervalSince1970)
        }

        if let conversationExpiresAt = options.conversationExpiresAt {
            payload.conversationExpiresAtUnix = Int64(conversationExpiresAt.timeIntervalSince1970)
        }

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        return try signedInvite.toURLSafeSlug()
    }
}

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
