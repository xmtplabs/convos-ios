import Foundation

/// Account identifiers for specific keychain items
enum KeychainAccount {
    /// Account for storing JWT tokens, keyed by device ID.
    ///
    /// This slot is used by the legacy device-only auth path
    /// (`POST /v2/auth/token` with body `{ deviceId }`) and by the
    /// Notification Service Extension. SIWE-bound JWTs must NOT be
    /// written here — they go to `siweJwt(deviceId:address:)` — so an
    /// NSE refresh (which mints a device-only token) can't accidentally
    /// stomp the main app's SIWE token, and vice versa.
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
}
