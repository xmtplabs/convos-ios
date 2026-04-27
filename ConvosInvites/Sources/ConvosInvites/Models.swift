import ConvosInvitesCore
import Foundation
@preconcurrency import XMTPiOS

// MARK: - Invite Options

/// Options for creating an invite
public struct InviteOptions: Sendable {
    /// Display name shown in the invite preview
    public var name: String?

    /// Description shown in the invite preview
    public var description: String?

    /// Image URL shown in the invite preview
    public var imageURL: URL?

    /// When the invite expires (nil = never)
    public var expiresAt: Date?

    /// Whether the invite can only be used once
    public var singleUse: Bool

    /// Whether to include public preview info in the invite
    public var includePublicPreview: Bool

    public init(
        name: String? = nil,
        description: String? = nil,
        imageURL: URL? = nil,
        expiresAt: Date? = nil,
        singleUse: Bool = false,
        includePublicPreview: Bool = true
    ) {
        self.name = name
        self.description = description
        self.imageURL = imageURL
        self.expiresAt = expiresAt
        self.singleUse = singleUse
        self.includePublicPreview = includePublicPreview
    }

    /// Create options with expiration relative to now
    public static func expiring(after interval: TimeInterval, singleUse: Bool = false) -> InviteOptions {
        InviteOptions(expiresAt: Date().addingTimeInterval(interval), singleUse: singleUse)
    }
}

// MARK: - Invite Creation Result

/// The result of creating an invite
public struct InviteCreationResult: Sendable {
    /// The URL-safe encoded invite slug (apps build the full URL from this)
    public let slug: String

    /// The underlying signed invite
    public let signedInvite: SignedInvite

    public init(slug: String, signedInvite: SignedInvite) {
        self.slug = slug
        self.signedInvite = signedInvite
    }
}

// MARK: - Join Request

/// A pending join request from someone trying to join a conversation
public struct JoinRequest: Sendable {
    /// The inbox ID of the person requesting to join
    public let joinerInboxId: String

    /// The DM conversation where the request was received
    public let dmConversationId: String

    /// The signed invite they presented
    public let signedInvite: SignedInvite

    /// The message containing the join request
    public let messageId: String

    /// The joiner's profile (name, image) if provided
    public let profile: JoinRequestProfile?

    /// Additional metadata (e.g., device name, confirmation code for Vault pairing)
    public let metadata: [String: String]?

    public init(
        joinerInboxId: String,
        dmConversationId: String,
        signedInvite: SignedInvite,
        messageId: String,
        profile: JoinRequestProfile? = nil,
        metadata: [String: String]? = nil
    ) {
        self.joinerInboxId = joinerInboxId
        self.dmConversationId = dmConversationId
        self.signedInvite = signedInvite
        self.messageId = messageId
        self.profile = profile
        self.metadata = metadata
    }
}

// MARK: - Join Result

/// The result of processing a join request
public struct JoinResult: Sendable {
    /// The conversation the joiner was added to
    public let conversationId: String

    /// The inbox ID of the person who joined
    public let joinerInboxId: String

    /// The name of the conversation (if available)
    public let conversationName: String?

    /// The joiner's profile if provided in the join request
    public let profile: JoinRequestProfile?

    /// Additional metadata from the join request
    public let metadata: [String: String]?

    public init(
        conversationId: String,
        joinerInboxId: String,
        conversationName: String?,
        profile: JoinRequestProfile? = nil,
        metadata: [String: String]? = nil
    ) {
        self.conversationId = conversationId
        self.joinerInboxId = joinerInboxId
        self.conversationName = conversationName
        self.profile = profile
        self.metadata = metadata
    }
}

// MARK: - Join Errors

/// Errors that can occur when processing join requests
public enum JoinRequestError: Error, Sendable {
    /// The invite signature is invalid
    case invalidSignature

    /// The invite has expired
    case expired

    /// The signed invite's `conversationExpiresAt` has passed
    case conversationExpired

    /// `findConversation` returned nil — libxmtp doesn't have the group locally
    case conversationNotFound(String)

    /// The conversation exists locally but its consent state is not `.allowed`
    case consentNotAllowed(String, ConsentState)

    /// The message is not a valid join request format
    case invalidFormat

    /// The creator inbox ID doesn't match
    case creatorMismatch

    /// The invite tag has been revoked (no longer matches group metadata)
    case revoked

    /// Failed to add the member to the group
    case addMemberFailed
}

/// Error types sent back to joiners when their request fails.
///
/// Wire-format compatibility: any unrecognized rawValue (from a newer client we
/// don't know about) decodes to `.conversationExpired` so older clients keep
/// the existing "this conversation is no longer available" UX.
public enum InviteJoinErrorType: Equatable, Sendable {
    /// The signed invite's `conversationExpiresAt` has passed
    case conversationExpired

    /// `findConversation` returned nil — libxmtp doesn't have the group locally
    case conversationNotFound

    /// The conversation exists locally but its consent state is not `.allowed`
    case consentNotAllowed

    case genericFailure

    public var rawValue: String {
        switch self {
        case .conversationExpired:
            return "conversation_expired"
        case .conversationNotFound:
            return "conversation_not_found"
        case .consentNotAllowed:
            return "consent_not_allowed"
        case .genericFailure:
            return "generic_failure"
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "conversation_expired":
            self = .conversationExpired
        case "conversation_not_found":
            self = .conversationNotFound
        case "consent_not_allowed":
            self = .consentNotAllowed
        case "generic_failure":
            self = .genericFailure
        default:
            self = .conversationExpired
        }
    }
}

extension InviteJoinErrorType: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self.init(rawValue: rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Error feedback sent to a joiner when their request fails
public struct InviteJoinError: Codable, Equatable, Sendable {
    public let errorType: InviteJoinErrorType
    public let inviteTag: String
    public let timestamp: Date

    public init(errorType: InviteJoinErrorType, inviteTag: String, timestamp: Date) {
        self.errorType = errorType
        self.inviteTag = inviteTag
        self.timestamp = timestamp
    }

    public var userFacingMessage: String {
        switch errorType {
        case .conversationExpired, .conversationNotFound, .consentNotAllowed:
            return "This conversation is no longer available"
        case .genericFailure:
            return "Failed to join conversation"
        }
    }
}
