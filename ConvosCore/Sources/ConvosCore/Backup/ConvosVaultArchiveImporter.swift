import ConvosInvites
import Foundation
@preconcurrency import XMTPiOS

public struct ConvosVaultArchiveImporter: VaultArchiveImporter {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public func importVaultArchive(
        from path: URL,
        encryptionKey: Data,
        vaultIdentity: KeychainIdentity
    ) async throws -> [VaultKeyEntry] {
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

        // Always import the archive from the backup into an isolated temp
        // directory. Reusing an existing vault XMTP DB on disk is wrong
        // when the keychain holds multiple vault identities (e.g. after
        // iCloud Keychain sync) — loadAny() might return the restoring
        // device's vault instead of the backup device's, and the existing
        // DB would contain a different set of key messages.
        let importDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmtp-vault-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: importDir)
        }
        Log.info("[Restore] importing vault archive into isolated directory (inboxId=\(vaultIdentity.inboxId))")

        let importOptions = ClientOptions(
            api: api,
            codecs: codecs,
            dbEncryptionKey: vaultIdentity.keys.databaseKey,
            dbDirectory: importDir.path,
            deviceSyncEnabled: false
        )

        // Client.create registers an installation on the XMTP network.
        // RestoreManager calls this BEFORE prepareForRestore so the
        // network is still available. The import runs in an isolated
        // temp directory and doesn't touch the app's live state.
        let client = try await Client.create(
            account: vaultIdentity.keys.signingKey,
            options: importOptions
        )
        defer { try? client.dropLocalDatabaseConnection() }

        Log.info("[Restore] importing vault archive (client inboxId=\(client.inboxID))")
        try await client.importArchive(path: path.path, encryptionKey: encryptionKey)
        Log.info("[Restore] vault archive import succeeded")

        return try await extractKeys(from: client)
    }

    private func extractKeys(from client: Client) async throws -> [VaultKeyEntry] {
        // Read groups and messages from the local DB only — no network sync.
        // The archive import already populated the local DB with everything
        // we need, and syncing would fail if the vault group was deactivated
        // on the network by a previous restore's revocation step.
        let groups = try client.conversations.listGroups()

        Log.info("[Restore] reading messages from \(groups.count) vault group(s)")
        var allMessages: [DecodedMessage] = []
        for group in groups {
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
        Log.info("[Restore] extracted \(entries.count) key entries from \(bundles.count) bundle(s) and \(shares.count) share(s)")
        return entries
    }
}
