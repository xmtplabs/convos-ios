import Foundation
@preconcurrency import XMTPiOS

/// Revokes the user's XMTP installations that aren't the current one.
///
/// Called at the tail end of `RestoreManager.restoreFromBackup` on the
/// restored device, after `importArchive` and before `resumeAfterRestore`.
/// Non-fatal on failure — the GRDB restore is the primary contract and a
/// revocation miss only leaves stale installations behind; the next restore
/// or reset will clean them up.
public enum XMTPInstallationRevoker {
    @discardableResult
    public static func revokeOtherInstallations(
        inboxId: String,
        signingKey: any SigningKey,
        keepInstallationId: String?,
        environment: AppEnvironment
    ) async throws -> Int {
        guard let keepInstallationId else {
            Log.warning("XMTPInstallationRevoker: refusing to revoke without a keeper installation id")
            return 0
        }

        let api = XMTPAPIOptionsBuilder.build(environment: environment)

        Log.info("XMTPInstallationRevoker: fetching inbox state for \(inboxId)")
        let states = try await Client.inboxStatesForInboxIds(
            inboxIds: [inboxId],
            api: api
        )

        guard let state = states.first else {
            Log.warning("XMTPInstallationRevoker: no inbox state found")
            return 0
        }

        let allIds = state.installations.map(\.id)
        if !allIds.contains(keepInstallationId) {
            Log.warning("XMTPInstallationRevoker: keeper installation \(keepInstallationId) is not visible in inbox state yet")
        }
        let toRevoke = allIds.filter { $0 != keepInstallationId }

        Log.info(
            "XMTPInstallationRevoker: found \(allIds.count) installation(s), "
            + "revoking \(toRevoke.count) (keeping \(keepInstallationId))"
        )

        guard !toRevoke.isEmpty else {
            return 0
        }

        try await Client.revokeInstallations(
            api: api,
            signingKey: signingKey,
            inboxId: inboxId,
            installationIds: toRevoke
        )

        Log.info("XMTPInstallationRevoker: revoked \(toRevoke.count) installation(s)")
        return toRevoke.count
    }
}
