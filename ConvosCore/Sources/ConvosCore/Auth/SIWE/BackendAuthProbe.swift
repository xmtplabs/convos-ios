import ConvosLogging
import Foundation

/// One-shot SIWE auth probe driven from the debug menu. Wraps the
/// nonce → sign → token → /account-auth-check round-trip so the host app
/// (which can't see internal types like `ConvosAPIClient`) can call a
/// single public method and render the result.
public enum BackendAuthProbe {
    public struct Result: Sendable {
        public let address: String
        public let jwt: String
        public let accountId: String?
        public let jwtExpiry: Date?
        public let accountAuthCheckPassed: Bool

        public init(
            address: String,
            jwt: String,
            accountId: String?,
            jwtExpiry: Date?,
            accountAuthCheckPassed: Bool
        ) {
            self.address = address
            self.jwt = jwt
            self.accountId = accountId
            self.jwtExpiry = jwtExpiry
            self.accountAuthCheckPassed = accountAuthCheckPassed
        }
    }

    public enum ProbeError: Error, CustomStringConvertible {
        case noIdentity
        case underlying(any Error)

        public var description: String {
            switch self {
            case .noIdentity:
                return "No on-device XMTP identity; sign in before running the probe."
            case .underlying(let err):
                return String(describing: err)
            }
        }
    }

    /// Runs the full positive path. Streams short progress lines through
    /// `progress` so the caller can render them in a log.
    public static func run(
        environment: AppEnvironment,
        identityStore: any KeychainIdentityStoreProtocol,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Result {
        let identity: KeychainIdentity
        do {
            guard let loaded = try await identityStore.load() else {
                throw ProbeError.noIdentity
            }
            identity = loaded
        } catch let err as ProbeError {
            throw err
        } catch {
            throw ProbeError.underlying(error)
        }

        let signing = BackendAuthSigningContext.make(from: identity.keys.privateKey)
        progress("Loaded identity (address=\(signing.address))")

        let appCheckToken: String
        do {
            appCheckToken = try await FirebaseHelperCore.getAppCheckToken()
        } catch {
            throw ProbeError.underlying(error)
        }
        progress("Got App Check token")

        let apiClient = ConvosAPIClientFactory.client(environment: environment)

        progress("Fetching nonce → signing → exchanging for JWT…")
        let jwt: String
        do {
            jwt = try await apiClient.authenticateWithSIWE(
                appCheckToken: appCheckToken,
                signing: signing,
                retryCount: 0
            )
        } catch {
            throw ProbeError.underlying(error)
        }

        let claims = decodeJWTClaims(jwt)
        let accountId = claims?["accountId"] as? String
        let expiry: Date? = (claims?["exp"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        if let accountId {
            progress("JWT received (accountId=\(accountId))")
        } else {
            progress("JWT received (no accountId — backend treated this as legacy path?)")
        }

        progress("Calling GET /v2/account-auth-check…")
        let response: ConvosAPI.AuthCheckResponse
        do {
            response = try await apiClient.accountAuthCheck(jwt: jwt)
        } catch {
            // Surface the gated-route failure as a soft result so the
            // debug screen can render the 401/403 instead of crashing.
            Log.warning("account-auth-check failed: \(error)")
            return Result(
                address: signing.address,
                jwt: jwt,
                accountId: accountId,
                jwtExpiry: expiry,
                accountAuthCheckPassed: false
            )
        }

        return Result(
            address: signing.address,
            jwt: jwt,
            accountId: accountId,
            jwtExpiry: expiry,
            accountAuthCheckPassed: response.success
        )
    }

    /// Negative-case probe: hits `/v2/account-auth-check` with no token
    /// and reports whether the backend rejected (the expected outcome).
    public static func probeWithoutAuth(environment: AppEnvironment) async -> Bool {
        let apiClient = ConvosAPIClientFactory.client(environment: environment)
        do {
            _ = try await apiClient.accountAuthCheck(jwt: nil)
            // Got 200 with no token — unexpected; gating is broken.
            return false
        } catch APIError.notAuthenticated, APIError.forbidden {
            return true
        } catch {
            Log.warning("Unauthenticated probe got unexpected error: \(error)")
            return false
        }
    }

    private static func decodeJWTClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        guard let data = try? String(parts[1]).base64URLDecoded(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
