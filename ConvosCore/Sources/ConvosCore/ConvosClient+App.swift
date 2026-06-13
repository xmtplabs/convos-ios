import ConvosMetrics
import Foundation

// App specific methods not needed in our tests target
extension ConvosClient {
    public static func client(
        environment: AppEnvironment,
        platformProviders: PlatformProviders,
        coreActions: any CoreActions
    ) -> ConvosClient {
        let databaseManager = DatabaseManager(environment: environment)
        let databaseWriter = databaseManager.dbWriter
        let databaseReader = databaseManager.dbReader
        // Device name is read lazily at each backup write (it can change
        // in Settings) and stamps the synced backup blob for the restore
        // picker, mirroring the pairing flow's device labels.
        let identityStore = KeychainIdentityStore(
            accessGroup: environment.keychainAccessGroup,
            deviceNameProvider: { DeviceInfo.deviceName }
        )
        let sessionManager = SessionManager(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment,
            identityStore: identityStore,
            platformProviders: platformProviders,
            coreActions: coreActions
        )
        LinkPreviewWriter.shared = LinkPreviewWriter(dbWriter: databaseWriter)
        // Wire the real backend credits service to the local database now
        // that the database is constructed. `BackendCreditsService` upserts
        // refresh results into `credit_balance`; views observe the table via
        // `CreditsRepository`. The mock fallback handles the non-production
        // debug toggle.
        CreditsServices.configure(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            apiClient: ConvosAPIClientFactory.client(environment: environment)
        )
        // Seed the credit_balance table on cold launch. The scene-phase
        // handler in `ConvosApp` covers subsequent foreground transitions,
        // but on first launch (or post-wipe) the table is empty until this
        // refresh lands. Forced so the 15s TTL doesn't gate an empty cache.
        // Views default `@State` to `nil` and update via `CreditsRepository`'s
        // GRDB observation when the row is upserted, so the brief window
        // before the refresh completes is acceptable.
        Task {
            await CreditsServices.shared.refresh(force: true)
        }
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
            expiredConversationsWorker: expiredConversationsWorker,
            scheduledExplosionManager: scheduledExplosionManager,
            platformProviders: platformProviders
        )
    }
}
