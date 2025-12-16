import Foundation

// MARK: - MessageInvite

public struct MessageInvite: Sendable, Hashable, Codable {
    public let inviteSlug: String
    public let conversationName: String?
    public let conversationDescription: String?
    public let imageURL: URL?
    public let expiresAt: Date?
    public let conversationExpiresAt: Date?
}

public extension MessageInvite {
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
            expiresAt: nil,
            conversationExpiresAt: nil
        )
    }
}
