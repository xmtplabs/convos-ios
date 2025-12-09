import ConvosCore
import Foundation
import SwiftUI

enum DeepLinkDestination {
    case joinConversation(inviteCode: String)
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

        guard let inviteCode = url.convosInviteCode else {
            Log.warning("Deep link is missing invite code")
            return nil
        }

        return .joinConversation(inviteCode: inviteCode)
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
