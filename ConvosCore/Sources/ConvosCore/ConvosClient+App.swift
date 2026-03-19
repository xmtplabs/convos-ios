import Foundation
import Security

// App specific methods not needed in our tests target
extension ConvosClient {
    public static func client(
        environment: AppEnvironment,
        platformProviders: PlatformProviders
    ) -> ConvosClient {
        let databaseManager = DatabaseManager(environment: environment)
        let databaseWriter = databaseManager.dbWriter
        let databaseReader = databaseManager.dbReader
        let keychainAccessGroup = environment.keychainAccessGroup

        KeychainIdentityStore.migrateToPlainAccessibilityIfNeeded(
            accessGroup: keychainAccessGroup,
            service: KeychainIdentityStore.defaultService,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        KeychainIdentityStore.migrateToPlainAccessibilityIfNeeded(
            accessGroup: keychainAccessGroup,
            service: Constant.vaultIdentityService,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        KeychainIdentityStore.migrateToPlainAccessibilityIfNeeded(
            accessGroup: keychainAccessGroup,
            service: Constant.vaultICloudIdentityService,
            accessibility: kSecAttrAccessibleAfterFirstUnlock
        )

        let identityStore = KeychainIdentityStore(accessGroup: keychainAccessGroup)
        let localVaultKeychainStore = KeychainIdentityStore(
            accessGroup: keychainAccessGroup,
            service: Constant.vaultIdentityService,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        let iCloudVaultKeychainStore = KeychainIdentityStore(
            accessGroup: keychainAccessGroup,
            service: Constant.vaultICloudIdentityService,
            accessibility: kSecAttrAccessibleAfterFirstUnlock,
            synchronizable: true
        )
        let vaultKeychainStore = ICloudIdentityStore(
            localStore: localVaultKeychainStore,
            icloudStore: iCloudVaultKeychainStore
        )
        Task {
            await vaultKeychainStore.syncLocalKeysToICloud()
        }

        let vaultKeyStore = VaultKeyStore(store: vaultKeychainStore)
        let vaultManager = VaultManager(
            identityStore: identityStore,
            vaultKeyStore: vaultKeyStore,
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
        LinkPreviewWriter.shared = LinkPreviewWriter(dbWriter: databaseWriter)
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

    private enum Constant {
        static let vaultIdentityService: String = "org.convos.vault-identity"
        static let vaultICloudIdentityService: String = "org.convos.vault-identity.icloud"
    }
}
