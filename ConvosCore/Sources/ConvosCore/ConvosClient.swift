import Combine
import Foundation
import GRDB

/// Main client interface for ConvosCore
///
/// ConvosClient provides the primary entry point for interacting with the Convos
/// messaging system. It manages the session lifecycle, database access, and environment
/// configuration. The client coordinates between the SessionManager (which handles
/// multiple messaging service instances) and the DatabaseManager (which provides
/// persistent storage).
public final class ConvosClient {
    private let sessionManager: any SessionManagerProtocol
    private let databaseManager: any DatabaseManagerProtocol
    private let environment: AppEnvironment
    public let expiredConversationsWorker: ExpiredConversationsWorkerProtocol?
    public let platformProviders: PlatformProviders

    var databaseWriter: any DatabaseWriter {
        databaseManager.dbWriter
    }

    var databaseReader: any DatabaseReader {
        databaseManager.dbReader
    }

    public var session: any SessionManagerProtocol {
        sessionManager
    }

    public static func testClient(platformProviders: PlatformProviders = .mock) -> ConvosClient {
        let databaseManager = MockDatabaseManager.shared
        let identityStore = MockKeychainIdentityStore()
        let sessionManager = SessionManager(
            databaseWriter: databaseManager.dbWriter,
            databaseReader: databaseManager.dbReader,
            environment: .tests,
            identityStore: identityStore,
            platformProviders: platformProviders
        )
        return .init(
            sessionManager: sessionManager,
            databaseManager: databaseManager,
            environment: .tests,
            expiredConversationsWorker: nil,
            platformProviders: platformProviders
        )
    }

    public static func mock(platformProviders: PlatformProviders = .mock) -> ConvosClient {
        let databaseManager = MockDatabaseManager.previews
        let sessionManager = MockInboxesService()
        return .init(
            sessionManager: sessionManager,
            databaseManager: databaseManager,
            environment: .tests,
            expiredConversationsWorker: nil,
            platformProviders: platformProviders
        )
    }

    internal init(
        sessionManager: any SessionManagerProtocol,
        databaseManager: any DatabaseManagerProtocol,
        environment: AppEnvironment,
        expiredConversationsWorker: ExpiredConversationsWorkerProtocol?,
        platformProviders: PlatformProviders
    ) {
        self.sessionManager = sessionManager
        self.databaseManager = databaseManager
        self.environment = environment
        self.expiredConversationsWorker = expiredConversationsWorker
        self.platformProviders = platformProviders
    }
}
