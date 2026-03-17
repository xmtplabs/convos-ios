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

        let options = ClientOptions(
            api: api,
            codecs: [
                ConversationDeletedCodec(),
                DeviceKeyBundleCodec(),
                DeviceKeyShareCodec(),
                DeviceRemovedCodec(),
                JoinRequestCodec(),
                PairingMessageCodec(),
                TextCodec(),
            ],
            dbEncryptionKey: vaultIdentity.keys.databaseKey
        )

        Log.info("[Restore] creating vault XMTP client for archive import")
        let client = try await Client.create(
            account: vaultIdentity.keys.signingKey,
            options: options
        )

        Log.info("[Restore] importing vault archive (inboxId: \(client.inboxID))")
        try await client.importArchive(path: path.path, encryptionKey: encryptionKey)

        Log.info("[Restore] syncing vault conversations after import")
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
        Log.info("[Restore] extracted \(entries.count) key entries from vault archive")

        try? client.dropLocalDatabaseConnection()
        return entries
    }
}
