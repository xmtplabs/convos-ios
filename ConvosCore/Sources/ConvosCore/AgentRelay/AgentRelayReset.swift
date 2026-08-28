import Foundation

/// Account-level wipe of everything the relay keeps on the device: transcript
/// rows, both providers' Keychain items, the connection defaults, the active
/// provider, and any staged composer draft. Called by the delete-all flow in
/// `SessionManager` before the account is torn down.
public enum AgentRelayReset {
    public static func wipeAll(environment: AppEnvironment) throws {
        try wipeAll(environment: environment, keychain: KeychainService())
    }

    static func wipeAll(environment: AppEnvironment, keychain: any KeychainServiceProtocol) throws {
        var firstError: Error?
        do {
            let database = try AgentChatDatabase(environment: environment)
            try AgentChatWriter(database: database).deleteAll()
        } catch {
            firstError = error
        }

        let connections = AgentConnectionStore(environment: environment, keychain: keychain)
        do {
            try connections.delete(provider: .town)
        } catch {
            if firstError == nil {
                firstError = error
            }
        }
        do {
            try connections.delete(provider: .tasklet)
        } catch {
            if firstError == nil {
                firstError = error
            }
        }
        PendingComposerDraftStore(environment: environment).clear()

        if let firstError {
            throw firstError
        }
    }
}
