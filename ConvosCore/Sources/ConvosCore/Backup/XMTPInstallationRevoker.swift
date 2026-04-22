import Foundation
@preconcurrency import XMTPiOS

/// Revokes every MLS installation on the user's inbox **except** the
/// one we want to keep — used at the tail of a restore to evict the
/// stale installation from the device whose backup we just unpacked.
///
/// Lives at the end of the restore flow: by the time this runs, the
/// throwaway `XMTPiOS.Client` already exists locally, its freshly-
/// minted installation is registered on the network, and we want to
/// revoke all the others so the old device's installation flips to
/// `stale` on its next foreground cycle.
///
/// Takes `any XMTPClientProvider` rather than a raw `XMTPiOS.Client`
/// so tests can inject a mock without spinning up a real XMTP client.
/// All network-talking calls go through the protocol's
/// `inboxState(refreshFromNetwork:)` + `revokeInstallations(signingKey:installationIds:)`.
///
/// The call is non-fatal: a revocation failure logs and returns; the
/// restore itself still counts as successful because the local GRDB +
/// XMTP archive are already committed.
public enum XMTPInstallationRevoker {
    public enum RevocationError: Error, LocalizedError {
        case noActiveInstallations

        public var errorDescription: String? {
            switch self {
            case .noActiveInstallations:
                return "Inbox state refresh returned zero installations — expected at least the local one"
            }
        }
    }

    /// Revoke every installation on this inbox except `keepInstallationId`.
    ///
    /// - Parameters:
    ///   - client: Live XMTP client for the inbox being revoked from.
    ///     Typically the throwaway `Client.build` `RestoreManager` just
    ///     finished calling `importArchive` on.
    ///   - signingKey: The identity's signing key. Needed to authorize
    ///     the revocation commits on the network.
    ///   - keepInstallationId: The id to preserve — almost always
    ///     `client.installationId` of the caller.
    /// - Returns: The number of installations that were revoked.
    @discardableResult
    public static func revokeOtherInstallations(
        client: any XMTPClientProvider,
        signingKey: any SigningKey,
        keepInstallationId: String
    ) async throws -> Int {
        Log.info("revokeOtherInstallations: fetching current inbox state")
        let state = try await client.inboxState(refreshFromNetwork: true)
        let allIds = state.installations.map(\.id)

        guard !allIds.isEmpty else {
            throw RevocationError.noActiveInstallations
        }

        let toRevoke = allIds.filter { $0 != keepInstallationId }
        Log.info("revokeOtherInstallations: \(allIds.count) active, revoking \(toRevoke.count), keeping \(keepInstallationId)")

        guard !toRevoke.isEmpty else {
            return 0
        }

        try await client.revokeInstallations(
            signingKey: signingKey,
            installationIds: toRevoke
        )
        Log.info("revokeOtherInstallations: revoked \(toRevoke.count) installation(s)")
        return toRevoke.count
    }
}
