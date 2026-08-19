import Foundation

/// Builds the URLSession configuration the API client uses, carrying the
/// per-PR preview token when this build was given one.
///
/// Preview backends (`https://pr-<N>.dev.convos.xyz`) are publicly resolvable,
/// so they refuse every request that arrives without the bundle's token -
/// `/healthcheck` is the only exemption. Stamping it on the session rather than
/// at each call site is deliberate: the gate also covers the unauthenticated
/// sign-in calls, so a per-request approach would have to remember
/// `/auth/nonce` and `/auth/token` too, and any route added later would
/// silently 503.
///
/// Every session that talks to the backend has to be built through here. The
/// sign-in calls run on their own cookie-disabled session, so a token stamped
/// only on the main one leaves `/auth/nonce` and `/auth/token` unauthorized
/// against a preview - which reads as a broken sign-in, not a missing header.
///
/// Only requests made through these configurations are stamped. The attachment
/// upload goes out on `URLSession.shared` to S3 and must not carry it.
public enum PreviewTokenSession {
    public static let header: String = "X-Preview-Token"

    /// - Parameter base: the configuration to stamp. Callers that need
    ///   specific transport behaviour pass their own - the SIWE session is
    ///   `.ephemeral` with cookie storage disabled, and must stay that way.
    public static func configuration(
        for environment: AppEnvironment,
        base: URLSessionConfiguration = .default
    ) -> URLSessionConfiguration {
        let previewToken: String = environment.previewToken
        guard !previewToken.isEmpty else { return base }
        base.httpAdditionalHeaders = [header: previewToken]
        return base
    }

    /// Session for callers that talk to the backend outside `ConvosAPIClient`'s
    /// own session. Reach for this instead of `URLSession.shared` for anything
    /// aimed at our API - `.shared` carries no token and 401s on a preview.
    public static func makeSession(for environment: AppEnvironment) -> URLSession {
        URLSession(configuration: configuration(for: environment))
    }

    /// Sign-in transport: ephemeral with cookie storage disabled, because
    /// SIWE's `__Host-` nonce cookie is carried manually as the `Cookie` header
    /// on `/auth/token` (see ConvosAPIClient+SIWECookieParsing). Built here so
    /// it is stamped like every other backend session - a file-static in the
    /// SIWE extension could not see the environment, which left `/auth/nonce`
    /// and `/auth/token` unauthorized against a preview.
    public static func makeSIWESession(for environment: AppEnvironment) -> URLSession {
        let base: URLSessionConfiguration = .ephemeral
        base.httpCookieStorage = nil
        base.httpShouldSetCookies = false
        base.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration(for: environment, base: base))
    }
}
