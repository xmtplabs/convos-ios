import Foundation
@preconcurrency import XMTPiOS

/// Probes the XMTP network for whether `installationId` is still in the
/// inbox's active installations set. Used by `SessionStateMachine` at
/// post-auth and on every foreground entry to detect the case where a
/// peer device revoked this installation (via the `Devices` screen).
///
/// Network/read failures are treated as `active = true` so a flaky XMTP
/// dev environment doesn't spuriously lock the user out. The check is
/// deliberately conservative: false negatives (treat-as-active when
/// revoked) are recoverable — the next probe will catch it. False
/// positives (treat-as-revoked when not) are not — they would force a
/// data wipe.
public enum XMTPInstallationStateChecker {
    public static func isInstallationActive(
        inboxId: String,
        installationId: String,
        environment: AppEnvironment
    ) async -> Bool {
        if environment.isTestingEnvironment {
            return true
        }
        let api = XMTPAPIOptionsBuilder.build(environment: environment)
        let states: [XMTPiOS.InboxState]
        do {
            states = try await Client.inboxStatesForInboxIds(inboxIds: [inboxId], api: api)
        } catch {
            Log.warning("XMTPInstallationStateChecker: inbox-state check failed, treating as active: \(error)")
            return true
        }
        guard let state = states.first else {
            Log.warning("XMTPInstallationStateChecker: empty inbox state, treating as active")
            return true
        }
        return state.installations.contains { $0.id == installationId }
    }
}
