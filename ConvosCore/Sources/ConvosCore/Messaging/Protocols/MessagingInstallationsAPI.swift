import Foundation

// MARK: - Installations API

/// Multi-installation management surface.
///
/// Surfaced from day one (audit §1.6 + open-question #1) even though
/// no call site drives it today. Stage 6 promotes
/// `revokeInstallations` / `revokeAllOtherInstallations` /
/// `inboxState` into real UI flows.
public protocol MessagingInstallationsAPI: Sendable {
    /// Current inbox's state, including every known installation.
    func inboxState(refreshFromNetwork: Bool) async throws -> MessagingInbox

    /// Batch lookup for a set of inboxes (for contact enrichment).
    func inboxStates(
        inboxIds: [MessagingInboxID],
        refreshFromNetwork: Bool
    ) async throws -> [MessagingInbox]

    /// Revokes a specific set of installations, signing the revocation
    /// with the supplied signer.
    func revokeInstallations(
        signer: any MessagingSigner,
        installationIds: [MessagingInstallationID]
    ) async throws

    /// Revokes every installation *other than* the currently-running
    /// one. Primary path for "log out of all other devices".
    func revokeAllOtherInstallations(signer: any MessagingSigner) async throws

    /// Static revocation. Used when no local `MessagingClient` is
    /// built (out-of-band account-recovery flows). The adapter spins
    /// up whatever ephemeral SDK state it needs from `config`.
    static func revokeInstallations(
        config: MessagingClientConfig,
        signer: any MessagingSigner,
        inboxId: MessagingInboxID,
        installationIds: [MessagingInstallationID]
    ) async throws
}
