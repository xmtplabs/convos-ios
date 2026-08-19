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
/// Only requests made through this configuration are stamped. The attachment
/// upload goes out on `URLSession.shared` to S3 and must not carry it.
enum PreviewTokenSession {
    static let header: String = "X-Preview-Token"

    static func configuration(for environment: AppEnvironment) -> URLSessionConfiguration {
        let configuration: URLSessionConfiguration = .default
        let previewToken: String = environment.previewToken
        guard !previewToken.isEmpty else { return configuration }
        configuration.httpAdditionalHeaders = [header: previewToken]
        return configuration
    }
}
