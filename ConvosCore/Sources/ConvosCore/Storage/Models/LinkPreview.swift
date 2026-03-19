import Foundation

public struct LinkPreview: Sendable, Hashable, Codable {
    public let url: String
    public let title: String?
    public let imageURL: String?
    public let siteName: String?
    public let imageWidth: Int?
    public let imageHeight: Int?

    public init(
        url: String,
        title: String? = nil,
        imageURL: String? = nil,
        siteName: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil
    ) {
        self.url = url
        self.title = title
        self.imageURL = imageURL
        self.siteName = siteName
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    public var imageAspectRatio: CGFloat? {
        guard let w = imageWidth, let h = imageHeight, w > 0, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }

    public var resolvedURL: URL? {
        URL(string: url)
    }

    public var displayHost: String {
        resolvedURL?.host ?? url
    }

    public func enriched(
        title: String? = nil,
        imageURL: String? = nil,
        siteName: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil
    ) -> LinkPreview {
        LinkPreview(
            url: url,
            title: title ?? self.title,
            imageURL: imageURL ?? self.imageURL,
            siteName: siteName ?? self.siteName,
            imageWidth: imageWidth ?? self.imageWidth,
            imageHeight: imageHeight ?? self.imageHeight
        )
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
