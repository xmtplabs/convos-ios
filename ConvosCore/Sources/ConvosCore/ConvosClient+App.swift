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
        let sessionManager = SessionManager(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment,
            identityStore: identityStore,
            platformProviders: platformProviders
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
