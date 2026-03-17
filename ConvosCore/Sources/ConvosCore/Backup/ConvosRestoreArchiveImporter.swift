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
            dbDirectory: environment.defaultDatabasesDirectory
        )

        let client = try await Client.build(
            publicIdentity: identity.keys.signingKey.identity,
            options: options,
            inboxId: inboxId
        )
        defer { try? client.dropLocalDatabaseConnection() }
        try await client.importArchive(path: path, encryptionKey: encryptionKey)
    }
}
