import Foundation

public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: String { inboxId }
    public let inboxId: String
    public let conversationId: String?
    public let name: String?
    public let avatar: String?
    public let avatarSalt: Data?
    public let avatarNonce: Data?

    public init(
        inboxId: String,
        conversationId: String? = nil,
        name: String?,
        avatar: String?,
        avatarSalt: Data? = nil,
        avatarNonce: Data? = nil
    ) {
        self.inboxId = inboxId
        self.conversationId = conversationId
        self.name = name
        self.avatar = avatar
        self.avatarSalt = avatarSalt
        self.avatarNonce = avatarNonce
    }

    public var avatarURL: URL? {
        guard let avatar, let url = URL(string: avatar) else {
            return nil
        }
        return url
    }

    public var isAvatarEncrypted: Bool {
        avatarSalt?.count == 32 && avatarNonce?.count == 12
    }

    public var displayName: String {
        name ?? "Somebody"
    }

    public func with(inboxId: String) -> Profile {
        .init(
            inboxId: inboxId,
            conversationId: conversationId,
            name: name,
            avatar: avatar,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce
        )
    }

    public static func empty(inboxId: String = "") -> Profile {
        .init(
            inboxId: inboxId,
            name: nil,
            avatar: nil
        )
    }

    public static func mock(inboxId: String = "", name: String = "Jane Doe") -> Profile {
        .init(
            inboxId: inboxId,
            name: name,
            avatar: "https://example.com/avatar.jpg"
        )
    }
}

// MARK: - Array Extensions

public extension Array where Element == Profile {
    var formattedNamesString: String {
        let namedProfiles = filter { $0.name != nil && $0.name?.isEmpty == false }
            .map { $0.displayName }
            .sorted()
        let anonymousCount = filter { $0.name == nil || $0.name?.isEmpty == true }.count

        var allNames = namedProfiles
        if anonymousCount > 1 {
            allNames.append("Somebodies")
        } else if anonymousCount == 1 {
            allNames.append("Somebody")
        }

        switch allNames.count {
        case 0:
            return ""
        case 1:
            return allNames[0]
        case 2:
            return allNames.joined(separator: " & ")
        default:
            return allNames.joined(separator: ", ")
        }
    }

    var hasAnyNamedProfile: Bool {
        contains { $0.name != nil && $0.name?.isEmpty == false }
    }

    var hasAnyAvatar: Bool {
        contains { $0.avatarURL != nil }
    }

    func sortedForCluster() -> [Profile] {
        sorted { p1, p2 in
            let p1HasAvatar = p1.avatarURL != nil
            let p2HasAvatar = p2.avatarURL != nil
            if p1HasAvatar != p2HasAvatar { return p1HasAvatar }

            let p1HasName = p1.name != nil && !(p1.name ?? "").isEmpty
            let p2HasName = p2.name != nil && !(p2.name ?? "").isEmpty
            if p1HasName != p2HasName { return p1HasName }

            return p1.inboxId < p2.inboxId
        }
    }
}
