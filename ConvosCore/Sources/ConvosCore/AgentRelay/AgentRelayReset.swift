import Foundation

/// Account-level wipe of everything the relay keeps on the device: transcript
/// rows, both providers' Keychain items, the connection defaults, the active
/// provider, and any staged composer draft. Called by the delete-all flow in
/// `SessionManager` before the account is torn down.
public enum AgentRelayReset {
    public static func wipeAll(environment: AppEnvironment) throws {}
}
