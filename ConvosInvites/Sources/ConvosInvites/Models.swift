import ConvosInvitesCore
import Foundation
import XMTPiOS

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

// MARK: - Invite URL

/// A shareable invite URL
public struct InviteURL: Sendable {
    /// The full URL to share
    public let url: URL

    /// The URL-safe encoded invite slug
    public let slug: String

    /// The underlying signed invite
    public let signedInvite: SignedInvite

    public init(url: URL, slug: String, signedInvite: SignedInvite) {
        self.url = url
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

    public init(
        joinerInboxId: String,
        dmConversationId: String,
        signedInvite: SignedInvite,
        messageId: String
    ) {
        self.joinerInboxId = joinerInboxId
        self.dmConversationId = dmConversationId
        self.signedInvite = signedInvite
        self.messageId = messageId
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

    public init(conversationId: String, joinerInboxId: String, conversationName: String?) {
        self.conversationId = conversationId
        self.joinerInboxId = joinerInboxId
        self.conversationName = conversationName
    }
}

// MARK: - Join Errors

/// Errors that can occur when processing join requests
public enum JoinRequestError: Error, Sendable {
    /// The invite signature is invalid
    case invalidSignature

    /// The invite has expired
    case expired

    /// The conversation has expired
    case conversationExpired

    /// The conversation was not found
    case conversationNotFound(String)

    /// The message is not a valid join request format
    case invalidFormat

    /// The creator inbox ID doesn't match
    case creatorMismatch

    /// The joiner is already a member
    case alreadyMember
}

/// Error types sent back to joiners when their request fails
public enum InviteJoinErrorType: String, Codable, Sendable {
    case conversationExpired
    case genericFailure
    case unknown
}

/// Error feedback sent to a joiner when their request fails
public struct InviteJoinError: Codable, Sendable {
    public let errorType: InviteJoinErrorType
    public let inviteTag: String
    public let timestamp: Date

    public init(errorType: InviteJoinErrorType, inviteTag: String, timestamp: Date) {
        self.errorType = errorType
        self.inviteTag = inviteTag
        self.timestamp = timestamp
    }
}
