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
    public let environment: AppEnvironment
    public let identityStore: any KeychainIdentityStoreProtocol
    public let expiredConversationsWorker: ExpiredConversationsWorkerProtocol?
    public let scheduledExplosionManager: ScheduledExplosionManagerProtocol?
    public let platformProviders: PlatformProviders

    public var databaseWriter: any DatabaseWriter {
        databaseManager.dbWriter
    }

    public var databaseReader: any DatabaseReader {
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
            identityStore: identityStore,
            expiredConversationsWorker: nil,
            scheduledExplosionManager: nil,
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
            identityStore: MockKeychainIdentityStore(),
            expiredConversationsWorker: nil,
            scheduledExplosionManager: nil,
            platformProviders: platformProviders
        )
    }

    internal init(
        sessionManager: any SessionManagerProtocol,
        databaseManager: any DatabaseManagerProtocol,
        environment: AppEnvironment,
        identityStore: any KeychainIdentityStoreProtocol,
        expiredConversationsWorker: ExpiredConversationsWorkerProtocol?,
        scheduledExplosionManager: ScheduledExplosionManagerProtocol?,
        platformProviders: PlatformProviders
    ) {
        self.sessionManager = sessionManager
        self.databaseManager = databaseManager
        self.environment = environment
        self.identityStore = identityStore
        self.expiredConversationsWorker = expiredConversationsWorker
        self.scheduledExplosionManager = scheduledExplosionManager
        self.platformProviders = platformProviders
    }

    /// Builds a `BackupManager` bound to the live session's client. Returns
    /// nil when the client isn't ready yet — `BackupScheduler` treats that
    /// as "skip, no identity yet."
    ///
    /// Constructed on demand rather than cached so a restore that rebuilds
    /// the cached service doesn't leave the scheduler holding a stale
    /// client resolver.
    public func makeBackupManager() -> BackupManager {
        let service = sessionManager.messagingService()
        let archiveProvider = ConvosBackupArchiveProvider { [weak service] () async throws -> (any XMTPClientProvider)? in
            guard let service else { return nil }
            let result = try await service.sessionStateManager.waitForInboxReadyResult()
            return result.client
        }
        return BackupManager(
            identityStore: identityStore,
            archiveProvider: archiveProvider,
            databaseReader: databaseManager.dbReader,
            deviceInfo: platformProviders.deviceInfo,
            environment: environment
        )
    }

    /// Builds a `RestoreManager` bound to this client's identity store +
    /// database manager. Lifecycle controller defaults to the live
    /// `SessionManager` if it conforms (it does).
    public func makeRestoreManager() -> RestoreManager {
        let lifecycleController = sessionManager as? any RestoreLifecycleControlling
        let environment = environment
        let revoker: RestoreInstallationRevoker = { inboxId, signingKey, keepId in
            try await XMTPInstallationRevoker.revokeOtherInstallations(
                inboxId: inboxId,
                signingKey: signingKey,
                keepInstallationId: keepId,
                environment: environment
            )
        }
        return RestoreManager(
            identityStore: identityStore,
            databaseManager: databaseManager,
            archiveImporter: ConvosRestoreArchiveImporter(environment: environment),
            lifecycleController: lifecycleController,
            installationRevoker: revoker,
            environment: environment
        )
    }
}
