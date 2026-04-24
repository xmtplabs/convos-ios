import ConvosInvites
import Foundation

// MARK: - MessageInvite

public struct MessageInvite: Sendable, Hashable, Codable {
    public let inviteSlug: String
    public let conversationName: String?
    public let conversationDescription: String?
    public let imageURL: URL?
    public let emoji: String?
    public let expiresAt: Date?
    public let conversationExpiresAt: Date?

    public init(
        inviteSlug: String,
        conversationName: String?,
        conversationDescription: String?,
        imageURL: URL?,
        emoji: String?,
        expiresAt: Date?,
        conversationExpiresAt: Date?
    ) {
        self.inviteSlug = inviteSlug
        self.conversationName = conversationName
        self.conversationDescription = conversationDescription
        self.imageURL = imageURL
        self.emoji = emoji
        self.expiresAt = expiresAt
        self.conversationExpiresAt = conversationExpiresAt
    }
}

public extension MessageInvite {
    /// The linked side conversation's scheduled explosion has passed.
    var isConversationExpired: Bool {
        guard let conversationExpiresAt else { return false }
        return conversationExpiresAt < Date()
    }

    /// The invite link itself has expired — separate from the conversation's
    /// explosion schedule. An invite can expire while the conversation is still
    /// live (e.g., a short-lived single-use link into a long-running convo).
    var isInviteExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    /// Attempts to parse a `MessageInvite` from text content.
    /// Returns `nil` if the text is not a valid Convos invite URL.
    /// - Parameter text: The text to parse (will be trimmed of whitespace)
    /// - Returns: A `MessageInvite` if the text contains a valid invite URL, otherwise `nil`
    static func from(text: String) -> MessageInvite? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedText),
              let inviteCode = url.convosInviteCode,
              let signedInvite = try? SignedInvite.fromInviteCode(inviteCode) else {
            return nil
        }
        let imageURL: URL? = signedInvite.imageURL.flatMap { URL(string: $0) }
        return MessageInvite(
            inviteSlug: inviteCode,
            conversationName: signedInvite.name,
            conversationDescription: signedInvite.description_p,
            imageURL: imageURL,
            emoji: signedInvite.emoji,
            expiresAt: signedInvite.expiresAt,
            conversationExpiresAt: signedInvite.conversationExpiresAt
        )
    }

    static var empty: MessageInvite {
        .init(
            inviteSlug: "message-invite-slug",
            conversationName: nil,
            conversationDescription: nil,
            imageURL: nil,
            emoji: nil,
            expiresAt: nil,
            conversationExpiresAt: nil
        )
    }

    static var mock: MessageInvite {
        .init(
            inviteSlug: "message-invite-slug",
            conversationName: "Untitled",
            conversationDescription: "A place to chat",
            imageURL: nil,
            emoji: "🦊",
            expiresAt: nil,
            conversationExpiresAt: nil
        )
    }

    static var mockExploded: MessageInvite {
        .init(
            inviteSlug: "message-invite-slug",
            conversationName: "Untitled",
            conversationDescription: "A place to chat",
            imageURL: nil,
            emoji: "🦊",
            expiresAt: nil,
            conversationExpiresAt: Date.distantPast
        )
    }

    static var mockInviteExpired: MessageInvite {
        .init(
            inviteSlug: "message-invite-slug",
            conversationName: "Untitled",
            conversationDescription: "A place to chat",
            imageURL: nil,
            emoji: "🦊",
            expiresAt: Date.distantPast,
            conversationExpiresAt: nil
        )
    }
}
