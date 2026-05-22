import ConvosCore
import Foundation
import SwiftUI

enum DeepLinkDestination {
    case joinConversation(inviteCode: String)
    case connectionGrant(serviceId: String, conversationId: String)
    case agentTemplate(templateId: String)
}

final class DeepLinkHandler {
    @MainActor
    static func destination(for url: URL) -> DeepLinkDestination? {
        let isValidScheme = url.scheme == "https" ?
            isValidHost(url.host) :
            url.scheme == ConfigManager.shared.appUrlScheme

        guard isValidScheme else {
            Log.warning("Dismissing deep link with invalid scheme")
            return nil
        }

        if let connectionGrantDestination = parseConnectionGrant(from: url) {
            return connectionGrantDestination
        }

        if let agentTemplateDestination = parseAgentTemplate(from: url) {
            return agentTemplateDestination
        }

        guard let inviteCode = url.convosInviteCode else {
            Log.warning("Deep link is missing invite code")
            return nil
        }

        return .joinConversation(inviteCode: inviteCode)
    }

    @MainActor
    private static func parseConnectionGrant(from url: URL) -> DeepLinkDestination? {
        guard isConnectionGrantURL(url) else {
            return nil
        }

        guard let (service, conversationId) = connectionGrantParams(from: url) else {
            return nil
        }

        guard CloudConnectionServiceCatalog.info(for: service) != nil else {
            Log.warning("Connection grant deep link references unknown service; dropping")
            return nil
        }

        guard isSafeConversationIdentifier(conversationId) else {
            Log.warning("Connection grant deep link has unsafe conversationId; dropping")
            return nil
        }

        return .connectionGrant(serviceId: service, conversationId: conversationId)
    }

    /// Split out so `parseConnectionGrant`'s body stays under the
    /// project's 100ms warn-long-function-bodies budget — chaining the
    /// optional `String?` comparisons with `&&` otherwise tips the
    /// type-checker over.
    private static func isConnectionGrantURL(_ url: URL) -> Bool {
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        if url.scheme == ConfigManager.shared.appUrlScheme,
           url.host == "connections",
           pathComponents.first == "grant" {
            return true
        }

        guard url.scheme == "https", pathComponents.count >= 2 else {
            return false
        }
        return pathComponents[0] == "connections" && pathComponents[1] == "grant"
    }

    private static func connectionGrantParams(from url: URL) -> (service: String, conversationId: String)? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let service = components?.queryItems?.first(where: { $0.name == "service" })?.value,
              let conversationId = components?.queryItems?.first(where: { $0.name == "conversationId" })?.value else {
            Log.warning("Connection grant deep link missing required query parameters")
            return nil
        }
        return (service, conversationId)
    }

    // MARK: - Agent template deep links

    /// Narrow agent-template check for callers (e.g. the QR scanner) that
    /// already have a candidate URL and want only the template id.
    /// Unlike `destination(for:)`, this does not fall through to invite
    /// parsing and logs nothing when `url` is not a template link, so a
    /// scanned conversation invite does not produce spurious warnings.
    @MainActor
    static func agentTemplateId(from url: URL) -> String? {
        guard case .agentTemplate(let templateId)? = parseAgentTemplate(from: url) else {
            return nil
        }
        return templateId
    }

    /// Parses agent-template deep links of the form
    /// `convos[-{env}]://template/<templateId>`, where `<templateId>` is
    /// the backend's `AgentTemplate.id` (a UUID).
    ///
    /// V1 handles the custom URL scheme only. A Universal Link form
    /// (`https://.../<templateId>`) is a planned follow-up.
    ///
    /// See `docs/plans/agent-templates-phase-1-prd.md`.
    @MainActor
    private static func parseAgentTemplate(from url: URL) -> DeepLinkDestination? {
        guard url.scheme == ConfigManager.shared.appUrlScheme,
              let templateId = customSchemeAgentTemplateId(from: url),
              isValidTemplateId(templateId) else {
            return nil
        }
        return .agentTemplate(templateId: templateId)
    }

    /// `convos[-{env}]://template/<id>` — host is `template`, single
    /// path component is the id.
    private static func customSchemeAgentTemplateId(from url: URL) -> String? {
        guard url.host == "template" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1 else { return nil }
        return components[0]
    }

    private static let uuidPattern: NSRegularExpression? = {
        // RFC 4122 v4 UUID, hex digits, case-insensitive — matches the
        // template id format the backend's resolver uses
        // (convos-backend/src/api/v2/agent-templates/lib/resolve-id-or-hashed-slug.ts).
        try? NSRegularExpression(
            pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            options: [.caseInsensitive]
        )
    }()

    private static func isValidTemplateId(_ value: String) -> Bool {
        guard let pattern = uuidPattern else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return pattern.firstMatch(in: value, options: [], range: range) != nil
    }

    private static let maxConversationIdLength: Int = 256

    private static func isSafeConversationIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maxConversationIdLength else {
            return false
        }
        // Conversation IDs from XMTP are hex strings; restrict to a conservative
        // alphanumeric + `-_` set so malformed or injection-style payloads are rejected
        // before they ever reach the repository layer.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isValidHost(_ host: String?) -> Bool {
        guard let host = host else {
            Log.warning("Deep link is missing host")
            return false
        }

        // Check against all configured associated domains
        return ConfigManager.shared.associatedDomains.contains(host)
    }
}
