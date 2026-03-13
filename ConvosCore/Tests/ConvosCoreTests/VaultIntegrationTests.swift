@testable import ConvosCore
import Foundation
import GRDB
import Testing
@preconcurrency import XMTPiOS

@Suite("Vault Integration Tests", .serialized, .timeLimit(.minutes(3)))
struct VaultIntegrationTests {
    private func makeVaultClient(keys: KeychainIdentityKeys) async throws -> (VaultClient, Client) {
        let isSecure: Bool
        if let envSecure = ProcessInfo.processInfo.environment["XMTP_IS_SECURE"] {
            isSecure = envSecure.lowercased() == "true" || envSecure == "1"
        } else {
            isSecure = false
        }

        let options = ClientOptions(
            api: .init(env: .local, isSecure: isSecure, appVersion: "convos-tests/1.0.0"),
            codecs: [
                ConversationDeletedCodec(),
                DeviceKeyBundleCodec(),
                DeviceKeyShareCodec(),
                DeviceRemovedCodec(),
                TextCodec(),
            ],
            dbEncryptionKey: keys.databaseKey,
            dbDirectory: AppEnvironment.tests.defaultDatabasesDirectory
        )

        let vaultClient = VaultClient()
        try await vaultClient.connect(signingKey: keys.signingKey, options: options)
        let xmtpClient = await vaultClient.xmtpClient
        return (vaultClient, xmtpClient!)
    }

    @Test("Two vault clients can form a vault group and exchange key bundles")
    func twoClientsExchangeKeys() async throws {
        let keysA = try KeychainIdentityKeys.generate()
        let keysB = try KeychainIdentityKeys.generate()

        let (vaultClientA, xmtpClientA) = try await makeVaultClient(keys: keysA)
        let (vaultClientB, _) = try await makeVaultClient(keys: keysB)

        let groupA = await vaultClientA.vaultGroup
        #expect(groupA != nil, "Device A should have a vault group")

        let inboxIdB = await vaultClientB.inboxId
        #expect(inboxIdB != nil)

        try await vaultClientA.addMember(inboxId: inboxIdB!)

        try await xmtpClientA.conversations.sync()
        try await vaultClientB.resyncVaultGroup()

        let membersA = try await vaultClientA.members()
        #expect(membersA.count == 2, "Vault group should have 2 members")

        let bundle = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(
                    conversationId: "conv-1",
                    inboxId: "inbox-shared",
                    clientId: "client-shared",
                    privateKeyData: Data([1, 2, 3]),
                    databaseKey: Data([4, 5, 6])
                ),
            ],
            senderInstallationId: await vaultClientA.installationId ?? "",
            senderDeviceName: "Test Device A"
        )

        try await vaultClientA.send(bundle, codec: DeviceKeyBundleCodec())

        let groupB = await vaultClientB.vaultGroup
        #expect(groupB != nil, "Device B should now have the vault group")

        try await groupB!.sync()
        let messagesB = try await groupB!.messages()

        var receivedBundle: DeviceKeyBundleContent?
        for message in messagesB {
            if let decoded: DeviceKeyBundleContent = try? message.content() {
                receivedBundle = decoded
                break
            }
        }

        #expect(receivedBundle != nil, "Device B should receive the key bundle")
        #expect(receivedBundle?.keys.count == 1)
        #expect(receivedBundle?.keys.first?.inboxId == "inbox-shared")
        #expect(receivedBundle?.senderDeviceName == "Test Device A")

        await vaultClientA.disconnect()
        await vaultClientB.disconnect()
        try? xmtpClientA.deleteLocalDatabase()
    }

    @Test("Conversation deletion broadcasts via vault group")
    func conversationDeletionBroadcast() async throws {
        let keysA = try KeychainIdentityKeys.generate()
        let keysB = try KeychainIdentityKeys.generate()

        let (vaultClientA, xmtpClientA) = try await makeVaultClient(keys: keysA)
        let (vaultClientB, _) = try await makeVaultClient(keys: keysB)

        let inboxIdB = await vaultClientB.inboxId
        try await vaultClientA.addMember(inboxId: inboxIdB!)
        try await vaultClientB.resyncVaultGroup()

        let deletion = ConversationDeletedContent(
            inboxId: "inbox-to-delete",
            clientId: "client-to-delete"
        )
        try await vaultClientA.send(deletion, codec: ConversationDeletedCodec())

        let groupB = await vaultClientB.vaultGroup
        try await groupB!.sync()
        let messagesB = try await groupB!.messages()

        var receivedDeletion: ConversationDeletedContent?
        for message in messagesB {
            if let decoded: ConversationDeletedContent = try? message.content() {
                receivedDeletion = decoded
                break
            }
        }

        #expect(receivedDeletion != nil, "Device B should receive the deletion message")
        #expect(receivedDeletion?.inboxId == "inbox-to-delete")
        #expect(receivedDeletion?.clientId == "client-to-delete")

        await vaultClientA.disconnect()
        await vaultClientB.disconnect()
        try? xmtpClientA.deleteLocalDatabase()
    }

    @Test("Orphaned solo vault groups are cleaned up on resync")
    func orphanedGroupCleanup() async throws {
        let keysA = try KeychainIdentityKeys.generate()
        let keysB = try KeychainIdentityKeys.generate()

        let (vaultClientA, xmtpClientA) = try await makeVaultClient(keys: keysA)
        let (vaultClientB, xmtpClientB) = try await makeVaultClient(keys: keysB)

        let soloGroupB = await vaultClientB.vaultGroup
        #expect(soloGroupB != nil, "Device B should have its solo vault group")
        let soloGroupBId = soloGroupB!.id

        let inboxIdB = await vaultClientB.inboxId
        try await vaultClientA.addMember(inboxId: inboxIdB!)

        try await vaultClientB.resyncVaultGroup()

        let currentGroupB = await vaultClientB.vaultGroup
        #expect(currentGroupB != nil)
        #expect(currentGroupB!.id != soloGroupBId, "Device B should have switched to Device A's vault group")

        let membersB = try await vaultClientB.members()
        #expect(membersB.count == 2, "Device B's active vault group should have 2 members")

        await vaultClientA.disconnect()
        await vaultClientB.disconnect()
        try? xmtpClientA.deleteLocalDatabase()
        try? xmtpClientB.deleteLocalDatabase()
    }
}
