import Foundation

public struct ArtifactManifest: Codable, Sendable, Equatable {
    public let bundleVersion: String
    public let createdAt: String
    public let title: String
    public let summary: String

    enum CodingKeys: String, CodingKey {
        case bundleVersion = "bundle_version"
        case createdAt = "created_at"
        case title
        case summary
    }

    public init(bundleVersion: String, createdAt: String, title: String, summary: String) {
        self.bundleVersion = bundleVersion
        self.createdAt = createdAt
        self.title = title
        self.summary = summary
    }
}
