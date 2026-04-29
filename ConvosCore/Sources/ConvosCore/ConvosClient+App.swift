import Foundation

// App specific methods not needed in our tests target
extension ConvosClient {
    public static func client(
        environment: AppEnvironment,
        platformProviders: PlatformProviders
    ) -> ConvosClient {
        let databaseManager = DatabaseManager(environment: environment)
        let recoveryOutcome = RestoreRecoveryManager(
            environment: environment,
            databaseManager: databaseManager
        ).recoverIfNeeded()
        if recoveryOutcome != .noTransaction {
            Log.warning("Restore recovery completed with outcome: \(recoveryOutcome)")
        }
        // Run the keychain layout migration before constructing the
        // identity store so the runtime store reads from the right
        // slot (v4-local) on its first call. Idempotent and gated on
        // an app-group UserDefaults marker — see
        // `docs/plans/single-inbox-two-key-model.md` for the rollout
        // notes (in particular: the destructive v3 deletion propagates
        // via iCloud Keychain, so this must not run while paired
        // devices are still on the pre-refactor build).
        let migrationOutcome = KeychainLayoutMigrator.migrateIfNeeded(environment: environment)
        if migrationOutcome != .alreadyMigrated && migrationOutcome != .freshInstall {
            Log.info("KeychainLayoutMigrator outcome: \(migrationOutcome)")
        }
        let databaseWriter = databaseManager.dbWriter
        let databaseReader = databaseManager.dbReader
        let identityStore = KeychainIdentityStore(accessGroup: environment.keychainAccessGroup)
        // Always start the bootstrap gate closed. The app-layer
        // BackupCoordinator resolves it to
        // .restoreAvailable / .noRestoreAvailable on first launch.
        //
        // This also covers the "identity synced via iCloud Keychain but no
        // local XMTP DB" scenario — on a new device, loadSync() returns an
        // identity (from iCloud Keychain sync), and without this gate the
        // `.authorize` path would silently fall back to Client.create,
        // registering a fresh installation on the existing inbox. That
        // looks to the user like a restore happened without consent.
        // Blocking all session construction until the coordinator's async
        // resolve pass completes closes that race.
        //
        // Clip and test contexts that bypass the coordinator need to pass
        // `initialBootstrapDecision: .noRestoreAvailable` explicitly.
        let sessionManager = SessionManager(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment,
            identityStore: identityStore,
            platformProviders: platformProviders,
            initialBootstrapDecision: .unknown
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
