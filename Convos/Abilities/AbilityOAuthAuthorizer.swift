import ConvosCore
import ConvosCoreiOS
import Foundation

/// Seam between `AbilitiesListViewModel`'s authorization step and the
/// system browser session. When an authorizer is injected (live abilities
/// backend), `beginEntitlement`'s redirect URL drives it instead of the
/// stub `AbilityAuthorizationSheet`; success and cancellation feed the same
/// complete/cancel lifecycle the sheet's buttons drive.
protocol AbilityAuthorizing: Sendable {
    /// Opens the provider consent page and returns once the OAuth callback
    /// hits the app's URL scheme. Throws `OAuthError.cancelled` when the
    /// user dismisses the browser sheet.
    func authorize(redirectUrl: String) async throws
}

enum AbilityOAuthAuthorizerError: LocalizedError {
    case invalidRedirectUrl(String)

    var errorDescription: String? {
        switch self {
        case .invalidRedirectUrl:
            "Couldn't open the sign-in page."
        }
    }
}

/// `AbilityAuthorizing` over `ASWebAuthenticationSession`, reusing the V1
/// cloud-connections OAuth machinery: the same `IOSOAuthSessionProvider`
/// and the same `<appUrlScheme>://connections/callback` convention the
/// backend's initiate flow redirects to. The callback URL's contents are
/// deliberately ignored -- ownership is verified server-side by
/// `completeEntitlement` via the connection-request id, exactly as V1's
/// complete does.
struct AbilityOAuthAuthorizer: AbilityAuthorizing {
    private let oauthProvider: any OAuthSessionProvider
    private let callbackURLScheme: String

    init(
        oauthProvider: any OAuthSessionProvider = IOSOAuthSessionProvider(),
        callbackURLScheme: String
    ) {
        self.oauthProvider = oauthProvider
        self.callbackURLScheme = callbackURLScheme
    }

    func authorize(redirectUrl: String) async throws {
        guard let url = URL(string: redirectUrl), url.scheme != nil else {
            throw AbilityOAuthAuthorizerError.invalidRedirectUrl(redirectUrl)
        }
        _ = try await oauthProvider.authenticate(url: url, callbackURLScheme: callbackURLScheme)
    }
}
