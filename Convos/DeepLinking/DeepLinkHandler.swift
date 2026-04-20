import ConvosCore
import Foundation
import SwiftUI

enum DeepLinkDestination {
    case joinConversation(inviteCode: String)
    case connectionGrant(serviceId: String, conversationId: String)
}

final class DeepLinkHandler {
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

    private static func parseConnectionGrant(from url: URL) -> DeepLinkDestination? {
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.first == "connections",
              pathComponents.count >= 2,
              pathComponents[1] == "grant" else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let service = components?.queryItems?.first(where: { $0.name == "service" })?.value,
              let conversationId = components?.queryItems?.first(where: { $0.name == "conversationId" })?.value else {
            Log.warning("Connection grant deep link missing required query parameters")
            return nil
        }

        return .connectionGrant(serviceId: service, conversationId: conversationId)
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
