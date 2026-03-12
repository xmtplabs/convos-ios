import Foundation
@preconcurrency import XMTPiOS

extension VaultManager {
    public func createArchive(at path: URL, encryptionKey: Data) async throws {
        try await vaultClient.createArchive(path: path.path, encryptionKey: encryptionKey)
    }

    @discardableResult
    public func importArchive(from path: URL, encryptionKey: Data) async throws -> [VaultKeyEntry] {
        try await vaultClient.importArchive(path: path.path, encryptionKey: encryptionKey)
        return try await extractKeys()
    }

    func extractKeys() async throws -> [VaultKeyEntry] {
        let messages = try await vaultClient.vaultGroupMessages()

        var bundles: [DeviceKeyBundleContent] = []
        var shares: [DeviceKeyShareContent] = []

        for message in messages {
            if let bundle: DeviceKeyBundleContent = try? message.content() {
                bundles.append(bundle)
            } else if let share: DeviceKeyShareContent = try? message.content() {
                shares.append(share)
            }
        }

        return Self.extractKeyEntries(bundles: bundles, shares: shares)
    }

    static func extractKeyEntries(
        bundles: [DeviceKeyBundleContent],
        shares: [DeviceKeyShareContent]
    ) -> [VaultKeyEntry] {
        var entriesByInboxId: [String: VaultKeyEntry] = [:]

        for bundle in bundles {
            for key in bundle.keys {
                entriesByInboxId[key.inboxId] = VaultKeyEntry(
                    inboxId: key.inboxId,
                    clientId: key.clientId,
                    conversationId: key.conversationId,
                    privateKeyData: key.privateKeyData,
                    databaseKey: key.databaseKey
                )
            }
        }

        for share in shares {
            entriesByInboxId[share.inboxId] = VaultKeyEntry(
                inboxId: share.inboxId,
                clientId: share.clientId,
                conversationId: share.conversationId,
                privateKeyData: share.privateKeyData,
                databaseKey: share.databaseKey
            )
        }

        return Array(entriesByInboxId.values)
    }
}
