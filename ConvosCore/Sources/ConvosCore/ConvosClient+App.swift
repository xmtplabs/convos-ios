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
        let identityStore = KeychainIdentityStore(
            accessGroup: environment.keychainAccessGroup,
            service: environment.keychainService
        )
        let sessionManager = SessionManager(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment,
            identityStore: identityStore,
            platformProviders: platformProviders
        )
        let expiredConversationsWorker = ExpiredConversationsWorker(
            databaseReader: databaseReader,
            sessionManager: sessionManager,
            appLifecycle: platformProviders.appLifecycle
        )
        return .init(
            sessionManager: sessionManager,
            databaseManager: databaseManager,
            environment: environment,
            expiredConversationsWorker: expiredConversationsWorker,
            platformProviders: platformProviders
        )
    }
}
