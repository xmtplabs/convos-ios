import ConvosCore
import Foundation
import Security

enum BackupManagerFactory {
    /// Builds a `BackupManager` from a live session. Returns nil if the
    /// vault isn't bootstrapped yet (no conversations / fresh install), so
    /// callers can skip the run instead of propagating an error.
    @MainActor
    static func make(
        session: any SessionManagerProtocol,
        environment: AppEnvironment
    ) -> BackupManager? {
        guard let vaultManager = session.vaultService as? VaultManager else {
            return nil
        }
        let accessGroup = environment.keychainAccessGroup
        let identityStore = KeychainIdentityStore(accessGroup: accessGroup)
        let vaultKeyStore = makeVaultKeyStore(environment: environment)
        let archiveProvider = ConvosBackupArchiveProvider(
            vaultService: vaultManager,
            identityStore: identityStore,
            environment: environment
        )
        return BackupManager(
            vaultKeyStore: vaultKeyStore,
            archiveProvider: archiveProvider,
            identityStore: identityStore,
            databaseReader: session.databaseReader,
            environment: environment
        )
    }

    static func makeVaultKeyStore(environment: AppEnvironment) -> VaultKeyStore {
        let accessGroup = environment.keychainAccessGroup
        let localStore = KeychainIdentityStore(
            accessGroup: accessGroup,
            service: "org.convos.vault-identity",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        let iCloudStore = KeychainIdentityStore(
            accessGroup: accessGroup,
            service: "org.convos.vault-identity.icloud",
            accessibility: kSecAttrAccessibleAfterFirstUnlock,
            synchronizable: true
        )
        let dualStore = ICloudIdentityStore(localStore: localStore, icloudStore: iCloudStore)
        return VaultKeyStore(store: dualStore)
    }
}
