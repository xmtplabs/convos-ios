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
    /// View-only flag populated at message-composition time by joining with the
    /// local `DBInvite`/`DBConversation` tables. Deliberately excluded from
    /// `CodingKeys` so it never lands in the persisted invite jsonText column.
    public let isConversationExpired: Bool

    private enum CodingKeys: String, CodingKey {
        case inviteSlug
        case conversationName
        case conversationDescription
        case imageURL
        case emoji
        case expiresAt
        case conversationExpiresAt
    }

    public init(
        inviteSlug: String,
        conversationName: String?,
        conversationDescription: String?,
        imageURL: URL?,
        emoji: String?,
        expiresAt: Date?,
        conversationExpiresAt: Date?,
        isConversationExpired: Bool = false
    ) {
        self.inviteSlug = inviteSlug
        self.conversationName = conversationName
        self.conversationDescription = conversationDescription
        self.imageURL = imageURL
        self.emoji = emoji
        self.expiresAt = expiresAt
        self.conversationExpiresAt = conversationExpiresAt
        self.isConversationExpired = isConversationExpired
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inviteSlug = try container.decode(String.self, forKey: .inviteSlug)
        conversationName = try container.decodeIfPresent(String.self, forKey: .conversationName)
        conversationDescription = try container.decodeIfPresent(String.self, forKey: .conversationDescription)
        imageURL = try container.decodeIfPresent(URL.self, forKey: .imageURL)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        conversationExpiresAt = try container.decodeIfPresent(Date.self, forKey: .conversationExpiresAt)
        isConversationExpired = false
    }
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
            emoji: signedInvite.emoji,
            expiresAt: signedInvite.expiresAt,
            conversationExpiresAt: signedInvite.conversationExpiresAt
        )
    }

    /// Returns a copy of the invite with `isConversationExpired` replaced.
    func with(isConversationExpired: Bool) -> MessageInvite {
        MessageInvite(
            inviteSlug: inviteSlug,
            conversationName: conversationName,
            conversationDescription: conversationDescription,
            imageURL: imageURL,
            emoji: emoji,
            expiresAt: expiresAt,
            conversationExpiresAt: conversationExpiresAt,
            isConversationExpired: isConversationExpired
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
            conversationExpiresAt: nil,
            isConversationExpired: true
        )
    }
}
