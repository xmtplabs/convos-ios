import Foundation

public struct Inbox: Codable, Hashable, Identifiable {
    public var id: String { inboxId }
    public let inboxId: String
    public let clientId: String
    public let createdAt: Date
    public let isVault: Bool
    public let installationId: String?
    public let isStale: Bool

    public init(
        inboxId: String,
        clientId: String,
        createdAt: Date = Date(),
        isVault: Bool = false,
        installationId: String? = nil,
        isStale: Bool = false
    ) {
        self.inboxId = inboxId
        self.clientId = clientId
        self.createdAt = createdAt
        self.isVault = isVault
        self.installationId = installationId
        self.isStale = isStale
    }

    // Custom decoder keeps `isStale` backwards-compatible with any JSON
    // payload written before the column was added. Swift's synthesized
    // Decodable ignores default init parameter values, so without this
    // override decoding old data would throw keyNotFound on `isStale`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.inboxId = try container.decode(String.self, forKey: .inboxId)
        self.clientId = try container.decode(String.self, forKey: .clientId)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.isVault = try container.decode(Bool.self, forKey: .isVault)
        self.installationId = try container.decodeIfPresent(String.self, forKey: .installationId)
        self.isStale = try container.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
    }
}
