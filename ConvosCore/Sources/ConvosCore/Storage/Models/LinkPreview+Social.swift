import Foundation

public enum SocialPlatform: String, Sendable {
    case twitter
    case threads
    case bluesky

    public var displayName: String {
        switch self {
        case .twitter: "X"
        case .threads: "Threads"
        case .bluesky: "Bluesky"
        }
    }

    public var logoAssetName: String {
        switch self {
        case .twitter: "xLogo"
        case .threads: "threadsLogo"
        case .bluesky: "blueskyLogo"
        }
    }
}

extension LinkPreview {
    private static let socialDomains: [String: SocialPlatform] = [
        "x.com": .twitter,
        "twitter.com": .twitter,
        "threads.net": .threads,
        "bsky.app": .bluesky,
    ]

    public var socialPlatform: SocialPlatform? {
        guard let host = resolvedURL?.host?.lowercased() else { return nil }
        let stripped = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return Self.socialDomains[stripped]
    }

    public var socialUsername: String? {
        guard let platform = socialPlatform,
              let url = resolvedURL else { return nil }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard !pathComponents.isEmpty else { return nil }

        switch platform {
        case .twitter:
            guard pathComponents.count >= 2,
                  pathComponents[1] == "status" else { return nil }
            return pathComponents[0]

        case .threads:
            guard !pathComponents.isEmpty else { return nil }
            let username = pathComponents[0]
            return username.hasPrefix("@") ? String(username.dropFirst()) : username

        case .bluesky:
            guard pathComponents.count >= 2,
                  pathComponents[0] == "profile" else { return nil }
            return pathComponents[1]
        }
    }
}
