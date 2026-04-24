import Foundation

// App specific methods not needed in our tests target
extension ConvosClient {
    public static func client(
        environment: AppEnvironment,
        platformProviders: PlatformProviders
    ) -> ConvosClient {
        let databaseManager = DatabaseManager(environment: environment)
        let databaseWriter = databaseManager.dbWriter
        let databaseReader = databaseManager.dbReader
        let identityStore = KeychainIdentityStore(accessGroup: environment.keychainAccessGroup)
        // Start with the bootstrap gate closed if no identity is present.
        // The app-layer BackupCoordinator resolves this to
        // .restoreAvailable / .noRestoreAvailable on first launch, which
        // keeps a fresh-install from minting a new identity before the
        // restore prompt card appears. Installs that already have an
        // identity open the gate immediately since loadOrCreateService's
        // register-branch guard only blocks when loadSync returns nil.
        let hasExistingIdentity = (try? identityStore.loadSync()) != nil
        let sessionManager = SessionManager(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment,
            identityStore: identityStore,
            platformProviders: platformProviders,
            initialBootstrapDecision: hasExistingIdentity ? .noRestoreAvailable : .unknown
        )
        LinkPreviewWriter.shared = LinkPreviewWriter(dbWriter: databaseWriter)
        let expiredConversationsWorker = ExpiredConversationsWorker(
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            sessionManager: sessionManager,
            appLifecycle: platformProviders.appLifecycle
        )
        let scheduledExplosionManager = ScheduledExplosionManager(
            databaseReader: databaseReader,
            appLifecycle: platformProviders.appLifecycle
        )
        return .init(
            sessionManager: sessionManager,
            databaseManager: databaseManager,
            environment: environment,
            identityStore: identityStore,
            expiredConversationsWorker: expiredConversationsWorker,
            scheduledExplosionManager: scheduledExplosionManager,
            platformProviders: platformProviders
        )
    }
}
