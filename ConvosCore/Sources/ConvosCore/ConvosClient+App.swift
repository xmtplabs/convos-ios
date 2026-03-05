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
        let vaultManager = VaultManager(
            identityStore: identityStore,
            databaseReader: databaseReader,
            deviceName: platformProviders.deviceInfo.deviceName
        )
        let sessionManager = SessionManager(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment,
            identityStore: identityStore,
            vaultService: vaultManager,
            platformProviders: platformProviders
        )
        let expiredConversationsWorker = ExpiredConversationsWorker(
            databaseReader: databaseReader,
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
            expiredConversationsWorker: expiredConversationsWorker,
            scheduledExplosionManager: scheduledExplosionManager,
            platformProviders: platformProviders
        )
    }
}
