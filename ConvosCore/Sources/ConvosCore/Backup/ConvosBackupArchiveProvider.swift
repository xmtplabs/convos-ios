import Foundation
@preconcurrency import XMTPiOS

public struct ConvosBackupArchiveProvider: BackupArchiveProvider {
    private let vaultService: any VaultServiceProtocol
    private let identityStore: any KeychainIdentityStoreProtocol
    private let environment: AppEnvironment

    public init(
        vaultService: any VaultServiceProtocol,
        identityStore: any KeychainIdentityStoreProtocol,
        environment: AppEnvironment
    ) {
        self.vaultService = vaultService
        self.identityStore = identityStore
        self.environment = environment
    }

    public func broadcastKeysToVault() async throws {
        guard let vaultManager = vaultService as? VaultManager else { return }
        try await vaultManager.shareAllKeys()
    }

    public func createVaultArchive(at path: URL, encryptionKey: Data) async throws {
        try await vaultService.createArchive(at: path, encryptionKey: encryptionKey)
    }

    public func createConversationArchive(inboxId: String, at path: String, encryptionKey: Data) async throws {
        let identity = try await identityStore.identity(for: inboxId)
        let client = try await buildClient(identity: identity, inboxId: inboxId)
        defer { try? client.dropLocalDatabaseConnection() }
        try await client.createArchive(path: path, encryptionKey: encryptionKey)
    }

    private func buildClient(identity: KeychainIdentity, inboxId: String) async throws -> Client {
        let api = XMTPAPIOptionsBuilder.build(environment: environment)
        let options = ClientOptions(
            api: api,
            dbEncryptionKey: identity.keys.databaseKey,
            dbDirectory: environment.defaultDatabasesDirectory
        )
        return try await Client.build(
            publicIdentity: identity.keys.signingKey.identity,
            options: options,
            inboxId: inboxId
        )
    }
}
