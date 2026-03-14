import Foundation

public struct LinkPreview: Sendable, Hashable, Codable {
    public let url: String
    public let title: String?
    public let imageURL: String?
    public let siteName: String?

    public init(
        url: String,
        title: String? = nil,
        imageURL: String? = nil,
        siteName: String? = nil
    ) {
        self.url = url
        self.title = title
        self.imageURL = imageURL
        self.siteName = siteName
    }

    public var resolvedURL: URL? {
        URL(string: url)
    }

    public var displayHost: String {
        resolvedURL?.host ?? url
    }

    public static var mock: LinkPreview {
        LinkPreview(
            url: "https://example.com/article",
            title: "Example Article Title",
            imageURL: "https://example.com/og-image.jpg",
            siteName: "Example"
        )
    }
}
