import ConvosCore
import Foundation
import XMTPDTU

/// DTU-backed implementation of `MessagingInstallationsAPI`.
///
/// DTU's engine surfaces installation state via `inbox_state` — an action
/// that returns the installation list + active/revoked state per inbox.
/// The adapter forwards `inboxState(...)` / `inboxStates(...)` onto this
/// action. Revocation flows (`revokeInstallations`,
/// `revokeAllOtherInstallations`, and the static revocation path used
/// for account recovery) do not exist in the engine today and throw
/// `DTUMessagingNotSupportedError`.
public final class DTUMessagingInstallationsAPI: MessagingInstallationsAPI, @unchecked Sendable {
    let context: DTUMessagingClientContext

    public init(context: DTUMessagingClientContext) {
        self.context = context
    }

    public func inboxState(refreshFromNetwork: Bool) async throws -> MessagingInbox {
        let state = try await context.universe.inboxState(inboxId: context.inboxAlias)
        return projected(state: state, fallbackInboxId: context.inboxAlias)
    }

    public func inboxStates(
        inboxIds: [MessagingInboxID],
        refreshFromNetwork: Bool
    ) async throws -> [MessagingInbox] {
        // DTU's `inbox_state` is single-inbox; fan out into per-inbox
        // calls and collect.
        var out: [MessagingInbox] = []
        out.reserveCapacity(inboxIds.count)
        for inboxId in inboxIds {
            let state = try await context.universe.inboxState(inboxId: inboxId)
            out.append(projected(state: state, fallbackInboxId: inboxId))
        }
        return out
    }

    public func revokeInstallations(
        signer: any MessagingSigner,
        installationIds: [MessagingInstallationID]
    ) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingInstallationsAPI.revokeInstallations",
            reason: "DTU engine does not model installation revocation"
        )
    }

    public func revokeAllOtherInstallations(signer: any MessagingSigner) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingInstallationsAPI.revokeAllOtherInstallations",
            reason: "DTU engine does not model installation revocation"
        )
    }

    public static func revokeInstallations(
        config: MessagingClientConfig,
        signer: any MessagingSigner,
        inboxId: MessagingInboxID,
        installationIds: [MessagingInstallationID]
    ) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingInstallationsAPI.revokeInstallations (static)",
            reason: "DTU engine does not model installation revocation, "
                + "and static revocation has no universe handle to target"
        )
    }

    // MARK: - Private helpers

    private func projected(
        state: DTUUniverse.InboxStateResult,
        fallbackInboxId: MessagingInboxID
    ) -> MessagingInbox {
        // DTU doesn't surface wallet identities on inbox state. Fill
        // `identities` + `recoveryIdentity` with a synthetic
        // `.ethereum` entry derived from the inbox alias — the
        // abstraction's callers today only use these fields for
        // display / comparison, and the alias is stable enough.
        let syntheticIdentity = MessagingIdentity(
            kind: .ethereum,
            identifier: state.inboxId
        )
        return MessagingInbox(
            inboxId: state.inboxId,
            identities: [syntheticIdentity],
            installations: state.installations.map(MessagingInstallation.init),
            recoveryIdentity: syntheticIdentity
        )
    }
}
