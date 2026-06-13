import Foundation

/// Account identifiers for specific keychain items
enum KeychainAccount {
    /// Account for storing JWT tokens, keyed by device ID.
    ///
    /// This slot is used by the legacy device-only auth path
    /// (`POST /v2/auth/token` with body `{ deviceId }`, no SIWE). It's
    /// what `ConvosAPIClient.authenticate(appCheckToken:)` reads/writes
    /// when no SIWE signing context is configured (e.g. during early
    /// boot before the on-device identity is loaded).
    ///
    /// Notes on the Notification Service Extension:
    /// - NSE itself does not read from this slot — it consumes the
    ///   `apiJWT` injected via the APNS payload and routes it through
    ///   `ConvosAPIClient.overrideJWTToken`.
    /// - The slot is still kept disjoint from
    ///   `siweJwt(deviceId:address:)` so a legacy `authenticate()`
    ///   call (e.g. fallback when SIWE isn't available yet) can't
    ///   stomp a SIWE-bound token stored under the address-scoped slot.
    static func jwt(deviceId: String) -> String {
        return deviceId
    }

    /// Account for storing SIWE-bound JWT tokens, keyed by device ID
    /// AND the Ethereum address of the signed-in identity. Scoping by
    /// address means a fresh sign-in with a different identity on the
    /// same device doesn't reuse a stale SIWE token from the previous
    /// account.
    static func siweJwt(deviceId: String, address: String) -> String {
        return "jwt:\(deviceId):siwe:\(address.lowercased())"
    }

    /// Account for storing the backend-assigned `accountId` for this
    /// (deviceId, address). The JWT also carries this claim, but the
    /// JWT expires every 15 minutes — this slot persists across
    /// expiries so the UI can keep showing "signed in as <accountId>"
    /// without re-authing, and so debug tooling can surface it even
    /// when the SIWE JWT is gone or stale.
    static func siweAccountId(deviceId: String, address: String) -> String {
        return "accountId:\(deviceId):siwe:\(address.lowercased())"
    }
}
