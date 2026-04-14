import Foundation
@preconcurrency import XMTPiOS

public enum XMTPInstallationRevoker {
    @discardableResult
    public static func revokeOtherInstallations(
        inboxId: String,
        signingKey: any SigningKey,
        keepInstallationId: String?,
        environment: AppEnvironment
    ) async throws -> Int {
        let api = XMTPAPIOptionsBuilder.build(environment: environment)

        Log.info("fetching inbox state for \(inboxId)")
        let states = try await Client.inboxStatesForInboxIds(
            inboxIds: [inboxId],
            api: api
        )

        guard let state = states.first else {
            Log.warning("no inbox state found")
            return 0
        }

        let allIds = state.installations.map(\.id)
        let toRevoke = allIds.filter { $0 != keepInstallationId }

        Log.info("found \(allIds.count) installation(s), revoking \(toRevoke.count) (keeping \(keepInstallationId ?? "none"))")

        guard !toRevoke.isEmpty else {
            return 0
        }

        try await Client.revokeInstallations(
            api: api,
            signingKey: signingKey,
            inboxId: inboxId,
            installationIds: toRevoke
        )

        Log.info("revoked \(toRevoke.count) installation(s)")
        return toRevoke.count
    }
}
