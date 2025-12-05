import Foundation

public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: String { inboxId }
    public let inboxId: String
    public let name: String?
    public let avatar: String?

    public init(inboxId: String, name: String?, avatar: String?) {
        self.inboxId = inboxId
        self.name = name
        self.avatar = avatar
    }

    public var avatarURL: URL? {
        guard let avatar, let url = URL(string: avatar) else {
            return nil
        }
        return url
    }

    public var displayName: String {
        name ?? "Somebody"
    }

    public func with(inboxId: String) -> Profile {
        .init(inboxId: inboxId, name: name, avatar: avatar)
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
        let displayNames = self.map { $0.displayName }
            .filter { !$0.isEmpty }
            .sorted()

        switch displayNames.count {
        case 0:
            return ""
        case 1:
            return displayNames[0]
        case 2:
            return displayNames.joined(separator: " & ")
        default:
            let allButLast = displayNames.dropLast().joined(separator: ", ")
            let last = displayNames.last ?? ""
            return "\(allButLast) and \(last)"
        }
    }
}
