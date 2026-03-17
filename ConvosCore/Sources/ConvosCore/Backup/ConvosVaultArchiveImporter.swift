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
        Log.info("[Restore] loading vault identity for temporary client")
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
            dbEncryptionKey: vaultIdentity.keys.databaseKey,
            dbDirectory: environment.defaultDatabasesDirectory
        )

        let tempClient: Client
        do {
            Log.info("[Restore] building vault XMTP client from local state")
            tempClient = try await Client.build(
                publicIdentity: vaultIdentity.keys.signingKey.identity,
                options: options,
                inboxId: vaultIdentity.inboxId
            )
        } catch {
            Log.info("[Restore] build failed (\(error)), creating vault XMTP client with signing key")
            tempClient = try await Client.create(
                account: vaultIdentity.keys.signingKey,
                options: options
            )
        }

        Log.info("[Restore] importing vault archive into client (inboxId: \(tempClient.inboxID))")
        try await tempClient.importArchive(path: path.path, encryptionKey: encryptionKey)

        Log.info("[Restore] extracting keys from imported vault messages")
        try await tempClient.conversations.sync()
        let groups = try tempClient.conversations.listGroups()
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
        Log.info("[Restore] extracted \(entries.count) key entries from vault")

        try? tempClient.dropLocalDatabaseConnection()
        return entries
    }
}
