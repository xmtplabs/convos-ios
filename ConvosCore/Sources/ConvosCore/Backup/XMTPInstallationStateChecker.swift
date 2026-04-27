import Foundation
@preconcurrency import XMTPiOS

public enum XMTPInstallationStateChecker {
    /// Returns true when the network still lists `installationId` as active.
    /// Network/read failures are treated as active so a transient outage does
    /// not block backup or spuriously lock the user out.
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
