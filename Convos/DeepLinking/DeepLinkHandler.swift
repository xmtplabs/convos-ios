import ConvosCore
import Foundation
import SwiftUI

enum DeepLinkDestination {
    case joinConversation(inviteCode: String)
    case connectionGrant(serviceId: String, conversationId: String)
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

        guard let inviteCode = url.convosInviteCode else {
            Log.warning("Deep link is missing invite code")
            return nil
        }

        return .joinConversation(inviteCode: inviteCode)
    }

    @MainActor
    private static func parseConnectionGrant(from url: URL) -> DeepLinkDestination? {
        // Cloud Connections feature flag — with the flag off, treat connection
        // grant URLs as unrecognized so they fall through to invite parsing
        // (and ultimately get rejected). Prevents soft-launch leak via universal
        // links the user never explicitly opted into.
        guard FeatureFlags.shared.isCloudConnectionsEnabled else {
            return nil
        }

        guard isConnectionGrantURL(url) else {
            return nil
        }

        guard let (service, conversationId) = connectionGrantParams(from: url) else {
            return nil
        }

        guard ConnectionServiceCatalog.info(for: service) != nil else {
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
