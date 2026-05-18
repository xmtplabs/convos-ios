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
                signing: signing
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

    /// Snapshot of the SIWE auth state on this device, read directly
    /// from Keychain without hitting the network. The JWT is the
    /// single source of truth for accountId — we deliberately don't
    /// shadow it in a separate slot.
    public struct Status: Sendable {
        public let address: String?    // checksummed EIP-55 form, nil if no identity
        public let jwt: String?        // SIWE JWT in keychain for this address
        public let accountId: String?  // decoded from JWT
        public let issuedAt: Date?
        public let jwtExpiry: Date?
        public let isJWTValid: Bool    // true iff JWT present, structurally valid, exp > now+60s
        /// Which slot the identity (private key) currently lives in:
        /// the synced (iCloud Keychain) slot, the legacy device-local
        /// slot, or missing entirely.
        public let identityStorage: IdentityStorageLocation

        public init(
            address: String?,
            jwt: String?,
            accountId: String?,
            issuedAt: Date?,
            jwtExpiry: Date?,
            isJWTValid: Bool,
            identityStorage: IdentityStorageLocation
        ) {
            self.address = address
            self.jwt = jwt
            self.accountId = accountId
            self.issuedAt = issuedAt
            self.jwtExpiry = jwtExpiry
            self.isJWTValid = isJWTValid
            self.identityStorage = identityStorage
        }
    }

    /// Reads the current SIWE auth state from Keychain. No network.
    /// Suitable for surfacing in debug UI / logs.
    public static func currentStatus(
        environment _: AppEnvironment,
        identityStore: any KeychainIdentityStoreProtocol
    ) async -> Status {
        let keychain = KeychainService()
        let deviceId = DeviceInfo.deviceIdentifier

        // load() migrates legacy → synced inline, so query the storage
        // location *after* the load to avoid reporting a stale .legacy.
        // `currentStorageLocation()` lives on the concrete store
        // (debug-only signal, intentionally not in the protocol);
        // mocks fall through to `.missing`.
        let identity: KeychainIdentity?
        identity = try? await identityStore.load()
        let storage: IdentityStorageLocation = (identityStore as? KeychainIdentityStore)?.currentStorageLocation() ?? .missing
        guard let identity else {
            return Status(
                address: nil,
                jwt: nil,
                accountId: nil,
                issuedAt: nil,
                jwtExpiry: nil,
                isJWTValid: false,
                identityStorage: storage
            )
        }

        let address = EthereumAddress.toChecksummed(identity.keys.privateKey.identity.identifier)
        let jwtSlot = KeychainAccount.siweJwt(deviceId: deviceId, address: address)
        let accountSlot = KeychainAccount.siweAccountId(deviceId: deviceId, address: address)
        let jwt = (try? keychain.retrieveString(account: jwtSlot)).flatMap { $0.isEmpty ? nil : $0 }
        let cachedAccountId = (try? keychain.retrieveString(account: accountSlot)).flatMap { $0.isEmpty ? nil : $0 }

        guard let jwt else {
            // No JWT but we may still know who they are from the
            // cached accountId slot — useful right after JWT expiry.
            return Status(
                address: address,
                jwt: nil,
                accountId: cachedAccountId,
                issuedAt: nil,
                jwtExpiry: nil,
                isJWTValid: false,
                identityStorage: storage
            )
        }

        let claims = decodeJWTClaims(jwt)
        let accountId = (claims?["accountId"] as? String) ?? cachedAccountId
        let issuedAt: Date? = (claims?["iat"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        let expiry: Date? = (claims?["exp"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        let isValid = expiry.map { $0 > Date().addingTimeInterval(60) } ?? false

        return Status(
            address: address,
            jwt: jwt,
            accountId: accountId,
            issuedAt: issuedAt,
            jwtExpiry: expiry,
            isJWTValid: isValid,
            identityStorage: storage
        )
    }

    /// Extracts the `accountId` claim from a SIWE JWT, or nil if the
    /// token is malformed / device-only / NSE-flavoured. Used by call
    /// sites that want to log the accountId without duplicating the
    /// base64url+JSON decode.
    public static func extractAccountId(from jwt: String) -> String? {
        decodeJWTClaims(jwt)?["accountId"] as? String
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
