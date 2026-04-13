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

    public func importConversationArchive(inboxId: String, path: String, encryptionKey: Data) async throws -> String {
        // RestoreManager has already staged/wiped the local XMTP DBs for conversation
        // inboxes before calling us, so no existing client can be reused here. Create
        // a single fresh client and import the archive into it — any prior `Client.build`
        // probe would register an extra installation on the network as a side effect.
        let identity = try await identityStore.identity(for: inboxId)
        let api = XMTPAPIOptionsBuilder.build(environment: environment)
        let options = ClientOptions(
            api: api,
            dbEncryptionKey: identity.keys.databaseKey,
            dbDirectory: environment.defaultDatabasesDirectory,
            deviceSyncEnabled: false
        )

        let client = try await Client.create(
            account: identity.keys.signingKey,
            options: options
        )
        defer { try? client.dropLocalDatabaseConnection() }

        try await client.importArchive(path: path, encryptionKey: encryptionKey)

        // After archive import, the XMTP SDK's consent state for restored
        // groups may be 'unknown'. shouldProcessConversation in StreamProcessor
        // drops messages from groups that aren't 'allowed', so the first
        // incoming message after restore would be silently lost. Set consent
        // to 'allowed' for all groups in this inbox's archive.
        let groups = try client.conversations.listGroups()
        for group in groups {
            try await group.updateConsentState(state: .allowed)
        }
        if !groups.isEmpty {
            Log.info("[Restore] set consent=allowed for \(groups.count) group(s) in \(inboxId)")
        }

        let newInstallationId = client.installationID
        Log.info("[Restore] conversation archive imported for \(inboxId) (new installationId=\(newInstallationId))")
        return newInstallationId
    }
}
