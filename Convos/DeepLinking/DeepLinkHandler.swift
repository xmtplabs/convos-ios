import ConvosCore
import Foundation
import SwiftUI

enum DeepLinkDestination {
    case joinConversation(inviteCode: String)
    case pairDevice(pairingId: String, expiresAt: Date?)
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

        if let pairingId = url.convosPairingId {
            return .pairDevice(pairingId: pairingId, expiresAt: url.convosPairingExpiresAt)
        }

        guard let inviteCode = url.convosInviteCode else {
            Log.warning("Deep link is missing invite code")
            return nil
        }

        return .joinConversation(inviteCode: inviteCode)
    }

    static func isPairingURL(_ url: URL) -> Bool {
        url.convosPairingId != nil
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

extension URL {
    var convosPairingId: String? {
        let pathComponents = pathComponents.filter { $0 != "/" }

        if scheme?.hasPrefix("convos") == true, host == "pair", pathComponents.count >= 1 {
            return pathComponents[0]
        }

        if pathComponents.first == "pair", pathComponents.count >= 2 {
            return pathComponents[1]
        }

        return nil
    }

    var convosPairingExpiresAt: Date? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let expiresString = components.queryItems?.first(where: { $0.name == "expires" })?.value,
              let expiresUnix = TimeInterval(expiresString)
        else { return nil }
        return Date(timeIntervalSince1970: expiresUnix)
    }
}
