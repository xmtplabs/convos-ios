import Foundation

/// Network-free, JWT-free snapshot of this device's own static identity
/// correlators, read directly from the keychain. Intended for the curated
/// prod debug menu's read-only Identity view.
///
/// This deliberately does not carry the SIWE JWT and never makes a network
/// call. It is the Tier-1 counterpart to `BackendAuthProbe.currentStatus`:
/// the prod-reachable identity surface reads only on-device, static values
/// and must never depend on the live token-minting probe. Keep it free of
/// any `BackendAuthProbe` reference so the prod menu cannot reach the
/// JWT-minting path.
public struct DeviceIdentitySnapshot: Sendable {
    /// Checksummed EIP-55 ethereum address, nil if there is no on-device identity.
    public let ethAddress: String?
    /// Backend-assigned accountId cached in the keychain, nil if absent.
    public let accountId: String?
    /// The XMTP inbox id for this device's identity.
    public let inboxId: String?
    /// The libxmtp client id (installation-scoped) for this identity.
    public let clientId: String?

    public init(
        ethAddress: String?,
        accountId: String?,
        inboxId: String?,
        clientId: String?
    ) {
        self.ethAddress = ethAddress
        self.accountId = accountId
        self.inboxId = inboxId
        self.clientId = clientId
    }

    /// Reads the static identity from the keychain. No network, no JWT.
    public static func current(
        identityStore: any KeychainIdentityStoreProtocol
    ) async -> DeviceIdentitySnapshot {
        let identity: KeychainIdentity?
        identity = try? await identityStore.load()
        guard let identity else {
            return DeviceIdentitySnapshot(ethAddress: nil, accountId: nil, inboxId: nil, clientId: nil)
        }
        let address = EthereumAddress.toChecksummed(identity.keys.privateKey.identity.identifier)
        let keychain = KeychainService()
        let deviceId = DeviceInfo.deviceIdentifier
        let accountSlot = KeychainAccount.siweAccountId(deviceId: deviceId, address: address)
        let rawAccountId: String?
        if let loaded = try? keychain.retrieveString(account: accountSlot) {
            rawAccountId = loaded
        } else {
            rawAccountId = nil
        }
        let cachedAccountId: String? = (rawAccountId?.isEmpty == true) ? nil : rawAccountId
        return DeviceIdentitySnapshot(
            ethAddress: address,
            accountId: cachedAccountId,
            inboxId: identity.inboxId,
            clientId: identity.clientId
        )
    }
}
