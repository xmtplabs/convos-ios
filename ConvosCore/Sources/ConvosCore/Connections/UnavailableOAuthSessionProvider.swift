import Foundation

/// An OAuthSessionProvider implementation for contexts where OAuth sessions are not supported
/// (e.g. app extensions or tests that don't exercise OAuth flows).
/// Unlike a mock, this throws a clear error if called so misconfigured composition is loud.
public final class UnavailableOAuthSessionProvider: OAuthSessionProvider, Sendable {
    public enum UnavailableError: Error, LocalizedError {
        case oauthNotSupported

        public var errorDescription: String? {
            "OAuth sessions are not supported in this context."
        }
    }

    public init() {}

    public func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
        throw UnavailableError.oauthNotSupported
    }
}
