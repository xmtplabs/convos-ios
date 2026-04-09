import Foundation
@preconcurrency import XMTPiOS

public struct ConvosRestoreArchiveImporter: RestoreArchiveImporter {
    private let identityStore: any KeychainIdentityStoreProtocol
    private let environment: AppEnvironment

    public init(
        identityStore: any KeychainIdentityStoreProtocol,
        environment: AppEnvironment
    ) {
        self.identityStore = identityStore
        self.environment = environment
    }

    public func importConversationArchive(inboxId: String, path: String, encryptionKey: Data) async throws {
        let identity = try await identityStore.identity(for: inboxId)
        let api = XMTPAPIOptionsBuilder.build(environment: environment)
        let options = ClientOptions(
            api: api,
            dbEncryptionKey: identity.keys.databaseKey,
            dbDirectory: environment.defaultDatabasesDirectory,
            deviceSyncEnabled: false
        )

        do {
            let client = try await Client.build(
                publicIdentity: identity.keys.signingKey.identity,
                options: options,
                inboxId: inboxId
            )
            try? client.dropLocalDatabaseConnection()
            Log.info("[Restore] conversation XMTP DB already exists for \(inboxId), skipping archive import")
            return
        } catch {
            Log.info("[Restore] no existing XMTP DB for \(inboxId), importing archive")
        }

        let client = try await Client.create(
            account: identity.keys.signingKey,
            options: options
        )
        defer { try? client.dropLocalDatabaseConnection() }

        try await client.importArchive(path: path, encryptionKey: encryptionKey)
        Log.info("[Restore] conversation archive imported for \(inboxId)")
    }
}
