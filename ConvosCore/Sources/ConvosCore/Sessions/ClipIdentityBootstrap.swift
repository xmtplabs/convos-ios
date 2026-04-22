import Foundation

/// Dedicated entry point for the App Clip. The clip's job is narrow:
/// write the user's single-inbox identity into the shared-app-group
/// keychain slot so the main app's first launch skips onboarding. It
/// has no push entitlement, no persistent streams, no need for asset
/// renewal, the unused-conversation prewarm, the
/// `ExpiredConversationsWorker` timer, or `LinkPreviewWriter`.
///
/// The full `ConvosClient.client(...)` factory spins up all of the
/// above and kicks off `SessionManager.initializationTask`, which in
/// an ephemeral clip process means work that is at best wasted and
/// at worst actively wrong (registering a push token against a clip).
/// This type instantiates only what the clip needs: a `SessionManager`
/// in `.clipBootstrap` mode plus the underlying database and keychain.
///
/// Main-app handoff works because both targets declare the same
/// `keychain-access-groups` entitlement. When the user later installs
/// the full app, `SessionManager.loadOrCreateService()` finds the
/// clip-seeded identity, takes the `.authorize` branch, and reuses
/// the inboxId + clientId + key material without re-onboarding.
public enum ClipIdentityBootstrap {
    /// Build the minimal session stack for the App Clip. Call once at
    /// clip launch and keep the returned value alive for the process.
    /// Triggers a single `messagingService()` call so the register path
    /// runs on first launch and the identity is written to the shared
    /// keychain; subsequent clip launches see the identity already
    /// present and take the authorize branch without re-registering.
    @MainActor
    public static func bootstrap(
        environment: AppEnvironment,
        platformProviders: PlatformProviders
    ) -> ClipSession {
        let databaseManager = DatabaseManager(environment: environment)
        let identityStore = KeychainIdentityStore(accessGroup: environment.keychainAccessGroup)
        let sessionManager = SessionManager(
            databaseWriter: databaseManager.dbWriter,
            databaseReader: databaseManager.dbReader,
            environment: environment,
            identityStore: identityStore,
            platformProviders: platformProviders,
            mode: .clipBootstrap
        )

        // Force the messaging service to materialize so the register
        // path runs and writes the identity. We don't wait for
        // authorization to complete — the clip doesn't need a ready
        // inbox to serve its UI, and the identity hits the keychain
        // as soon as `handleRegister`'s `identityStore.save` returns,
        // well before `.ready`.
        _ = sessionManager.messagingService()

        return ClipSession(
            sessionManager: sessionManager,
            databaseManager: databaseManager
        )
    }

    /// Retained handle from `bootstrap` — keep alive for the clip's
    /// lifetime so the session's background work (identity-write,
    /// authentication) can settle. No messaging API is exposed because
    /// the clip doesn't send or receive messages; its UI is a "tap to
    /// open the full app" affordance.
    public struct ClipSession: @unchecked Sendable {
        let sessionManager: SessionManager
        let databaseManager: DatabaseManager
    }
}
