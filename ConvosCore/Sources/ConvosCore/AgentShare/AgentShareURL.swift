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

    /// The published web link the backend hands out, of the form
    /// `https://<convos.org host>/a/<slug>`. The host varies by environment --
    /// `agents-dev.convos.org/a/...` in dev, `convos.org/a/...` in prod -- so
    /// match any `convos.org` host (apex or subdomain) and key on the reserved
    /// `/a/` path segment as the agent-page signal. The path must be exactly
    /// `/a/<slug>`; a bare `/<slug>` is intentionally not matched (it would
    /// swallow ordinary marketing pages like `convos.org/about`).
    private static func webSlug(from url: URL) -> String? {
        guard url.scheme == "https", isConvosHost(url.host) else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 2, components[0] == Constant.webPathPrefix else {
            return nil
        }
        let slug = components[1]
        guard !slug.isEmpty else { return nil }
        return slug
    }

    /// Matches `convos.org` (apex) and any subdomain of it
    /// (`agents-dev.convos.org`, `app.convos.org`, ...).
    private static func isConvosHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == Constant.convosDomainSuffix || host.hasSuffix("." + Constant.convosDomainSuffix)
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
        static let convosDomainSuffix: String = "convos.org"
        static let webPathPrefix: String = "a"
    }
}
