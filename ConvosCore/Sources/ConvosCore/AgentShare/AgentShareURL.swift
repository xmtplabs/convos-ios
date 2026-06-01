import Foundation

/// A parsed agent-share link. Shares a published agent template so a
/// recipient can render a contact card for it and pop open a conversation
/// seeded with that agent. The parallel of `ConvosInvites`' invite-URL
/// parsing, but far lighter: an agent-share link carries no signed payload,
/// only an identifier the backend resolves to the template's public profile.
///
/// Two link shapes are recognized:
///  - custom scheme `convos[-env]://template/<templateId>` (a UUID), the same
///    form `DeepLinkHandler` already routes for in-app template deep links;
///  - web `https://agents[-env].convos.org/<slug>`, where `<slug>` is the
///    backend's hashed url slug (`<base>.<hash>`).
///
/// In both shapes `identifier` is whatever the backend's resolver accepts
/// (`:idOrHashedSlug`) -- the UUID for the scheme form, the slug for the web
/// form -- and `url` is the original absolute string, preserved so the sent
/// message body is the link the user pasted.
public struct AgentShareURL: Hashable, Sendable {
    public let identifier: String
    public let url: String

    public init(identifier: String, url: String) {
        self.identifier = identifier
        self.url = url
    }

    /// Parses `text` (trimmed) as a single agent-share link, returning `nil`
    /// when it isn't one. Mirrors `MessageInvite.from(text:)`'s contract so
    /// the message classifier can call both the same way.
    public static func from(text: String) -> AgentShareURL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        return from(url: url)
    }

    public static func from(url: URL) -> AgentShareURL? {
        if let identifier = customSchemeTemplateId(from: url) {
            return AgentShareURL(identifier: identifier, url: url.absoluteString)
        }
        if let slug = webSlug(from: url) {
            return AgentShareURL(identifier: slug, url: url.absoluteString)
        }
        return nil
    }

    /// `convos[-env]://template/<uuid>` -- host is `template`, the single path
    /// component is the template id. Matches `DeepLinkHandler`'s scheme form.
    ///
    /// The scheme is matched by prefix (`convos`, `convos-dev`,
    /// `convos-local`, `convos-pr`) rather than against
    /// `ConfigManager.shared.appUrlScheme`. This keeps the classifier free of a
    /// process-wide config dependency (ConfigManager isn't installed in
    /// `ConvosCore`'s test environment) and lets it recognize a link authored
    /// in any environment.
    private static func customSchemeTemplateId(from url: URL) -> String? {
        guard isConvosScheme(url.scheme), url.host == Constant.templateHost else {
            return nil
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1, isValidTemplateId(components[0]) else {
            return nil
        }
        return components[0]
    }

    private static func isConvosScheme(_ scheme: String?) -> Bool {
        guard let scheme else { return false }
        return scheme == Constant.schemeBase || scheme.hasPrefix(Constant.schemeBase + "-")
    }

    /// `https://agents[-env].convos.org/a/<slug>` -- the published web link the
    /// backend hands out (e.g. `agents-dev.convos.org/a/gandalf.felpl`). The
    /// host varies by environment (`agents-dev.convos.org` in dev; the prod
    /// host is not finalized), so match any `agents`-prefixed `convos.org`
    /// subdomain rather than pinning a single host. The path is `/a/<slug>`; a
    /// bare `/<slug>` is also accepted for resilience.
    private static func webSlug(from url: URL) -> String? {
        guard url.scheme == "https", isAgentsHost(url.host) else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        let slug: String?
        switch components.count {
        case 1 where components[0] != Constant.webPathPrefix:
            // Bare `/<slug>`. Exclude a lone `a` so a trailing-slash `/a/`
            // (which collapses to `["a"]`) isn't misread as the slug "a".
            slug = components[0]
        case 2 where components[0] == Constant.webPathPrefix:
            slug = components[1]
        default:
            slug = nil
        }
        guard let slug, !slug.isEmpty else { return nil }
        return slug
    }

    /// Matches `agents.convos.org` and any env-suffixed sibling
    /// (`agents-dev.convos.org`, `agents-local.convos.org`, ...). The leading
    /// DNS label must be `agents` or `agents-<env>`, and the remainder must be
    /// exactly `convos.org`.
    private static func isAgentsHost(_ host: String?) -> Bool {
        guard let host, let dotIndex = host.firstIndex(of: ".") else { return false }
        let label = String(host[host.startIndex..<dotIndex])
        let remainder = String(host[host.index(after: dotIndex)...])
        guard remainder == Constant.convosDomainSuffix else { return false }
        return label == Constant.agentsHostPrefix || label.hasPrefix(Constant.agentsHostPrefix + "-")
    }

    private static func isValidTemplateId(_ value: String) -> Bool {
        guard let pattern = uuidPattern else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return pattern.firstMatch(in: value, options: [], range: range) != nil
    }

    private static let uuidPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            options: [.caseInsensitive]
        )
    }()

    private enum Constant {
        static let schemeBase: String = "convos"
        static let templateHost: String = "template"
        static let agentsHostPrefix: String = "agents"
        static let convosDomainSuffix: String = "convos.org"
        static let webPathPrefix: String = "a"
    }
}
