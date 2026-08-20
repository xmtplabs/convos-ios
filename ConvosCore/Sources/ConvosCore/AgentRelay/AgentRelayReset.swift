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
        let database = try AgentChatDatabase(environment: environment)
        try AgentChatWriter(database: database).deleteAll()

        let connections = AgentConnectionStore(environment: environment, keychain: keychain)
        try connections.delete(provider: .town)
        try connections.delete(provider: .tasklet)
        PendingComposerDraftStore(environment: environment).clear()
    }
}
