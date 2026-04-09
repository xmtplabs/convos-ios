import ConvosInvites
import Foundation
@preconcurrency import XMTPiOS

public struct ConvosVaultArchiveImporter: VaultArchiveImporter {
    private let vaultKeyStore: VaultKeyStore
    private let environment: AppEnvironment

    public init(vaultKeyStore: VaultKeyStore, environment: AppEnvironment) {
        self.vaultKeyStore = vaultKeyStore
        self.environment = environment
    }

    public func importVaultArchive(from path: URL, encryptionKey: Data) async throws -> [VaultKeyEntry] {
        Log.info("[Restore] loading vault identity")
        let vaultIdentity = try await vaultKeyStore.loadAny()
        let api = XMTPAPIOptionsBuilder.build(environment: environment)

        let codecs: [any ContentCodec] = [
            ConversationDeletedCodec(),
            DeviceKeyBundleCodec(),
            DeviceKeyShareCodec(),
            DeviceRemovedCodec(),
            JoinRequestCodec(),
            PairingMessageCodec(),
            TextCodec(),
        ]

        let existingOptions = ClientOptions(
            api: api,
            codecs: codecs,
            dbEncryptionKey: vaultIdentity.keys.databaseKey,
            deviceSyncEnabled: false
        )

        if let existingClient = try? await Client.build(
            publicIdentity: vaultIdentity.keys.signingKey.identity,
            options: existingOptions,
            inboxId: vaultIdentity.inboxId
        ) {
            Log.info("[Restore] vault XMTP DB already exists, extracting keys from existing vault")
            defer { try? existingClient.dropLocalDatabaseConnection() }
            try await existingClient.conversations.sync()
            return try await extractKeys(from: existingClient)
        }

        let importDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmtp-vault-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
        Log.info("[Restore] no existing vault XMTP DB, importing archive into isolated directory")

        let importOptions = ClientOptions(
            api: api,
            codecs: codecs,
            dbEncryptionKey: vaultIdentity.keys.databaseKey,
            dbDirectory: importDir.path,
            deviceSyncEnabled: false
        )

        let client = try await Client.create(
            account: vaultIdentity.keys.signingKey,
            options: importOptions
        )

        Log.info("[Restore] importing vault archive (inboxId: \(client.inboxID))")
        try await client.importArchive(path: path.path, encryptionKey: encryptionKey)
        Log.info("[Restore] vault archive import succeeded")

        let entries = try await extractKeys(from: client)
        try? client.dropLocalDatabaseConnection()
        try? FileManager.default.removeItem(at: importDir)
        return entries
    }

    private func extractKeys(from client: Client) async throws -> [VaultKeyEntry] {
        try await client.conversations.sync()
        let groups = try client.conversations.listGroups()

        Log.info("[Restore] reading messages from \(groups.count) vault group(s)")
        var allMessages: [DecodedMessage] = []
        for group in groups {
            try await group.sync()
            let messages = try await group.messages()
            allMessages.append(contentsOf: messages)
        }

        var bundles: [DeviceKeyBundleContent] = []
        var shares: [DeviceKeyShareContent] = []
        for message in allMessages {
            if let bundle: DeviceKeyBundleContent = try? message.content() {
                bundles.append(bundle)
            } else if let share: DeviceKeyShareContent = try? message.content() {
                shares.append(share)
            }
        }

        let entries = VaultManager.extractKeyEntries(bundles: bundles, shares: shares)
        Log.info("[Restore] extracted \(entries.count) key entries")
        return entries
    }
}
