import Foundation

// App specific methods not needed in our tests target
extension ConvosClient {
    public static func client(environment: AppEnvironment) -> ConvosClient {
        let databaseManager = DatabaseManager(environment: environment)
        let databaseWriter = databaseManager.dbWriter
        let databaseReader = databaseManager.dbReader
        let identityStore = KeychainIdentityStore(accessGroup: environment.keychainAccessGroup)
        let sessionManager = SessionManager(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment,
            identityStore: identityStore
        )
        let expiredConversationsWorker = ExpiredConversationsWorker(
            databaseReader: databaseReader,
            sessionManager: sessionManager
        )
        return .init(
            sessionManager: sessionManager,
            databaseManager: databaseManager,
            environment: environment,
            expiredConversationsWorker: expiredConversationsWorker
        )
    }
}
