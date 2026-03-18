import ConvosProfiles
import Foundation

public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: String { inboxId }
    public let inboxId: String
    public let conversationId: String?
    public let name: String?
    public let avatar: String?
    public let avatarSalt: Data?
    public let avatarNonce: Data?
    public let avatarKey: Data?
    public let isAgent: Bool
    public let metadata: ProfileMetadata?

    private enum CodingKeys: String, CodingKey {
        case inboxId, conversationId, name, avatar, avatarSalt, avatarNonce, avatarKey, isAgent, metadata
    }

    public init(
        inboxId: String,
        conversationId: String? = nil,
        name: String?,
        avatar: String?,
        avatarSalt: Data? = nil,
        avatarNonce: Data? = nil,
        avatarKey: Data? = nil,
        isAgent: Bool = false,
        metadata: ProfileMetadata? = nil
    ) {
        self.inboxId = inboxId
        self.conversationId = conversationId
        self.name = name
        self.avatar = avatar
        self.avatarSalt = avatarSalt
        self.avatarNonce = avatarNonce
        self.avatarKey = avatarKey
        self.isAgent = isAgent
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.inboxId = try container.decode(String.self, forKey: .inboxId)
        self.conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        self.avatarSalt = try container.decodeIfPresent(Data.self, forKey: .avatarSalt)
        self.avatarNonce = try container.decodeIfPresent(Data.self, forKey: .avatarNonce)
        self.avatarKey = try container.decodeIfPresent(Data.self, forKey: .avatarKey)
        self.isAgent = try container.decodeIfPresent(Bool.self, forKey: .isAgent) ?? false
        self.metadata = try container.decodeIfPresent(ProfileMetadata.self, forKey: .metadata)
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

    public func verifyAssistantAttestation(keyset: any AgentKeysetProviding) async -> Bool {
        guard isAgent,
              let attestation = metadata?["attestation"],
              let timestamp = metadata?["attestation_ts"],
              let kid = metadata?["attestation_kid"],
              case .string(let sig) = attestation,
              case .string(let ts) = timestamp,
              case .string(let keyId) = kid
        else { return false }
        return await AssistantAttestationVerifier.verify(
            inboxId: inboxId,
            attestation: sig,
            attestationTimestamp: ts,
            kid: keyId,
            keyset: keyset
        )
    }

    public func verifyCachedAssistantAttestation(keyset: any AgentKeysetProviding) -> Bool {
        guard isAgent,
              let attestation = metadata?["attestation"],
              let timestamp = metadata?["attestation_ts"],
              let kid = metadata?["attestation_kid"],
              case .string(let sig) = attestation,
              case .string(let ts) = timestamp,
              case .string(let keyId) = kid
        else { return false }
        return AssistantAttestationVerifier.verifyCached(
            inboxId: inboxId,
            attestation: sig,
            attestationTimestamp: ts,
            kid: keyId,
            keyset: keyset
        )
    }

    public var isOutOfCredits: Bool {
        guard let credits = metadata?["credits"] else { return false }
        switch credits {
        case .number(let value):
            return value <= 0
        case .bool(let value):
            return !value
        case .string:
            return false
        }
    }

    public func with(inboxId: String) -> Profile {
        .init(
            inboxId: inboxId,
            conversationId: conversationId,
            name: name,
            avatar: avatar,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce,
            avatarKey: avatarKey,
            isAgent: isAgent,
            metadata: metadata
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
        let totalCount = namedProfiles.count + anonymousCount

        if namedProfiles.isEmpty {
            if anonymousCount == 0 {
                return ""
            } else if anonymousCount == 1 {
                return "Somebody"
            } else {
                return "Somebodies"
            }
        }

        let maxNames = NameLimits.maxDisplayedMemberNames

        if totalCount <= maxNames {
            var allNames = namedProfiles
            if anonymousCount > 1 {
                allNames.append("Somebodies")
            } else if anonymousCount == 1 {
                allNames.append("Somebody")
            }

            switch allNames.count {
            case 1:
                return allNames[0]
            case 2:
                return allNames.joined(separator: " & ")
            default:
                return allNames.joined(separator: ", ")
            }
        }

        let namesPrefix = namedProfiles.prefix(maxNames)
        let othersCount = totalCount - namesPrefix.count
        let othersText = othersCount == 1 ? "1 other" : "\(othersCount) others"

        return namesPrefix.joined(separator: ", ") + " and " + othersText
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
