@testable import ConvosCore
import Foundation
import Testing

/// Invariants that keep the SIWE rollout from polluting the legacy
/// device-only JWT slot.
///
/// The legacy slot (`KeychainAccount.jwt(deviceId:)`) is the
/// fallback path `ConvosAPIClient.authenticate(appCheckToken:)` uses
/// when no SIWE signing context is configured. The NSE itself does
/// not read this slot — it consumes an APNS-injected JWT via
/// `overrideJWTToken` — but the slot still needs to stay disjoint
/// from the SIWE slot so a legacy auth call can't stomp a SIWE-bound
/// token and vice versa. These tests pin that disjointness.
@Suite("SIWE/legacy slot disjointness")
struct SIWENSECompatibilityTests {
    @Test("Legacy and SIWE Keychain accounts are different strings")
    func slotsAreDisjoint() {
        let deviceId = "device-abc-123"
        let address = "0xAbCdEf0123456789aBCdEF0123456789AbcDef01"
        let legacy = KeychainAccount.jwt(deviceId: deviceId)
        let siwe = KeychainAccount.siweJwt(deviceId: deviceId, address: address)
        #expect(legacy != siwe)
        #expect(siwe.contains("siwe"))
        #expect(siwe.contains(address.lowercased()))
        #expect(!siwe.contains(address)) // address is forced lowercase in the slot key
    }

    @Test("SIWE slot is address-scoped: different addresses → different slots")
    func siweSlotScopedByAddress() {
        let deviceId = "device-X"
        let a = KeychainAccount.siweJwt(deviceId: deviceId, address: "0xAAA")
        let b = KeychainAccount.siweJwt(deviceId: deviceId, address: "0xBBB")
        #expect(a != b)
    }

    @Test("Keychain writes to legacy and SIWE slots are independent")
    func keychainWritesDoNotCollide() throws {
        // Use the in-memory mock — the simulator unit-test keychain
        // can be flaky without an entitlements file, and this test is
        // about the *account-keyed* disjoint behavior, not the real
        // Keychain backend. The Keychain backend is a thin wrapper over
        // `SecItemAdd` keyed by `kSecAttrAccount`, so independence at
        // the protocol level guarantees independence at the real
        // backend.
        let svc: any KeychainServiceProtocol = MockKeychainService()
        let deviceId = "test-disjoint-device"
        let address = "0xAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAa"

        try svc.saveString("legacy-token", account: KeychainAccount.jwt(deviceId: deviceId))
        try svc.saveString("siwe-token", account: KeychainAccount.siweJwt(deviceId: deviceId, address: address))

        #expect(try svc.retrieveString(account: KeychainAccount.jwt(deviceId: deviceId)) == "legacy-token")
        #expect(try svc.retrieveString(account: KeychainAccount.siweJwt(deviceId: deviceId, address: address)) == "siwe-token")

        // Sanity: deleting one doesn't touch the other.
        try svc.delete(account: KeychainAccount.siweJwt(deviceId: deviceId, address: address))
        #expect(try svc.retrieveString(account: KeychainAccount.jwt(deviceId: deviceId)) == "legacy-token")
        #expect(try svc.retrieveString(account: KeychainAccount.siweJwt(deviceId: deviceId, address: address)) == nil)
    }

    @Test("jwtCarriesAccountId() identifies SIWE vs non-SIWE JWTs")
    func jwtAccountIdDetection() throws {
        // Legacy device-only payload — no accountId.
        let devicePayload = try jwtFromClaims(["sub": "device-1", "deviceId": "device-1"])
        #expect(ConvosAPIClient.jwtCarriesAccountId(devicePayload) == false)

        // SIWE-bound payload — accountId present.
        let siwePayload = try jwtFromClaims([
            "sub": "device-1",
            "deviceId": "device-1",
            "accountId": "9c21f30a-a448-49af-87af-9239b24b6494",
        ])
        #expect(ConvosAPIClient.jwtCarriesAccountId(siwePayload) == true)

        // NSE-flavoured payload — has metadata.notificationExtensionOnly,
        // no accountId. Classified as "not SIWE" (the SIWE slot writer
        // refuses to store it). Note: the backend's
        // /api/v2/account-auth-check route rejects this token at
        // authMiddleware time with 403 "NSE tokens not allowed on this
        // route", not at requireAccount with "Account required" — but
        // either way the iOS-side classifier here just needs to refuse
        // to treat it as SIWE.
        let nsePayload = try jwtFromClaims([
            "sub": "device-1",
            "deviceId": "device-1",
            "metadata": ["notificationExtensionOnly": true],
        ])
        #expect(ConvosAPIClient.jwtCarriesAccountId(nsePayload) == false)
    }
}

// MARK: - Test helpers

/// Constructs a *structurally* valid JWT (header.payload.signature) for
/// use with `ConvosAPIClient.jwtCarriesAccountId`. We don't need a real
/// signature — that method only inspects the payload claims.
private func jwtFromClaims(_ claims: [String: Any]) throws -> String {
    let header: [String: Any] = ["alg": "ES256", "typ": "JWT"]
    let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    let payloadData = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    return "\(base64URL(headerData)).\(base64URL(payloadData)).sig"
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
