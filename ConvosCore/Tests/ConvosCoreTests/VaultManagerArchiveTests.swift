@testable import ConvosCore
import Foundation
import Testing

@Suite("VaultManager Archive Tests")
struct VaultManagerArchiveTests {
    // MARK: - extractKeyEntries: Empty inputs

    @Test("Returns empty when no bundles or shares")
    func extractEmptyInputs() {
        let result = VaultManager.extractKeyEntries(bundles: [], shares: [])
        #expect(result.isEmpty)
    }

    // MARK: - extractKeyEntries: Bundles only

    @Test("Extracts keys from a single bundle with one key")
    func extractSingleBundleSingleKey() {
        let bundle = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(
                    conversationId: "conv-1",
                    inboxId: "inbox-1",
                    clientId: "client-1",
                    privateKeyData: Data([1, 2, 3]),
                    databaseKey: Data([4, 5, 6])
                ),
            ],
            senderInstallationId: "install-1"
        )

        let result = VaultManager.extractKeyEntries(bundles: [bundle], shares: [])

        #expect(result.count == 1)
        #expect(result[0].inboxId == "inbox-1")
        #expect(result[0].clientId == "client-1")
        #expect(result[0].conversationId == "conv-1")
        #expect(result[0].privateKeyData == Data([1, 2, 3]))
        #expect(result[0].databaseKey == Data([4, 5, 6]))
    }

    @Test("Extracts keys from a single bundle with multiple keys")
    func extractSingleBundleMultipleKeys() {
        let bundle = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "conv-1", inboxId: "inbox-1", clientId: "client-1", privateKeyData: Data([1]), databaseKey: Data([2])),
                DeviceKeyEntry(conversationId: "conv-2", inboxId: "inbox-2", clientId: "client-2", privateKeyData: Data([3]), databaseKey: Data([4])),
                DeviceKeyEntry(conversationId: "conv-3", inboxId: "inbox-3", clientId: "client-3", privateKeyData: Data([5]), databaseKey: Data([6])),
            ],
            senderInstallationId: "install-1"
        )

        let result = VaultManager.extractKeyEntries(bundles: [bundle], shares: [])

        #expect(result.count == 3)
        let ids = Set(result.map(\.inboxId))
        #expect(ids == ["inbox-1", "inbox-2", "inbox-3"])
    }

    @Test("Extracts keys from multiple bundles")
    func extractMultipleBundles() {
        let bundle1 = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "conv-1", inboxId: "inbox-1", clientId: "client-1", privateKeyData: Data([1]), databaseKey: Data([2])),
            ],
            senderInstallationId: "install-1"
        )
        let bundle2 = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "conv-2", inboxId: "inbox-2", clientId: "client-2", privateKeyData: Data([3]), databaseKey: Data([4])),
            ],
            senderInstallationId: "install-2"
        )

        let result = VaultManager.extractKeyEntries(bundles: [bundle1, bundle2], shares: [])

        #expect(result.count == 2)
        let ids = Set(result.map(\.inboxId))
        #expect(ids == ["inbox-1", "inbox-2"])
    }

    @Test("Later bundle overwrites earlier bundle for same inboxId")
    func bundleOverwritesSameInboxId() {
        let bundle1 = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "conv-old", inboxId: "inbox-1", clientId: "client-old", privateKeyData: Data([1]), databaseKey: Data([2])),
            ],
            senderInstallationId: "install-1"
        )
        let bundle2 = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "conv-new", inboxId: "inbox-1", clientId: "client-new", privateKeyData: Data([9]), databaseKey: Data([10])),
            ],
            senderInstallationId: "install-2"
        )

        let result = VaultManager.extractKeyEntries(bundles: [bundle1, bundle2], shares: [])

        #expect(result.count == 1)
        #expect(result[0].clientId == "client-new")
        #expect(result[0].conversationId == "conv-new")
        #expect(result[0].privateKeyData == Data([9]))
        #expect(result[0].databaseKey == Data([10]))
    }

    // MARK: - extractKeyEntries: Shares only

    @Test("Extracts key from a single share")
    func extractSingleShare() {
        let share = DeviceKeyShareContent(
            conversationId: "conv-1",
            inboxId: "inbox-1",
            clientId: "client-1",
            privateKeyData: Data([7, 8, 9]),
            databaseKey: Data([10, 11, 12]),
            senderInstallationId: "install-1"
        )

        let result = VaultManager.extractKeyEntries(bundles: [], shares: [share])

        #expect(result.count == 1)
        #expect(result[0].inboxId == "inbox-1")
        #expect(result[0].clientId == "client-1")
        #expect(result[0].conversationId == "conv-1")
        #expect(result[0].privateKeyData == Data([7, 8, 9]))
        #expect(result[0].databaseKey == Data([10, 11, 12]))
    }

    @Test("Extracts keys from multiple shares with different inboxIds")
    func extractMultipleShares() {
        let shares = [
            DeviceKeyShareContent(conversationId: "conv-1", inboxId: "inbox-1", clientId: "client-1", privateKeyData: Data([1]), databaseKey: Data([2]), senderInstallationId: "i1"),
            DeviceKeyShareContent(conversationId: "conv-2", inboxId: "inbox-2", clientId: "client-2", privateKeyData: Data([3]), databaseKey: Data([4]), senderInstallationId: "i2"),
            DeviceKeyShareContent(conversationId: "conv-3", inboxId: "inbox-3", clientId: "client-3", privateKeyData: Data([5]), databaseKey: Data([6]), senderInstallationId: "i3"),
        ]

        let result = VaultManager.extractKeyEntries(bundles: [], shares: shares)

        #expect(result.count == 3)
        let ids = Set(result.map(\.inboxId))
        #expect(ids == ["inbox-1", "inbox-2", "inbox-3"])
    }

    @Test("Later share overwrites earlier share for same inboxId")
    func shareOverwritesSameInboxId() {
        let shares = [
            DeviceKeyShareContent(conversationId: "conv-old", inboxId: "inbox-1", clientId: "client-old", privateKeyData: Data([1]), databaseKey: Data([2]), senderInstallationId: "i1"),
            DeviceKeyShareContent(conversationId: "conv-new", inboxId: "inbox-1", clientId: "client-new", privateKeyData: Data([9]), databaseKey: Data([10]), senderInstallationId: "i2"),
        ]

        let result = VaultManager.extractKeyEntries(bundles: [], shares: shares)

        #expect(result.count == 1)
        #expect(result[0].clientId == "client-new")
        #expect(result[0].privateKeyData == Data([9]))
    }

    // MARK: - extractKeyEntries: Mixed bundles and shares

    @Test("Combines keys from bundles and shares with different inboxIds")
    func extractMixedDifferentInboxIds() {
        let bundle = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "conv-1", inboxId: "inbox-1", clientId: "client-1", privateKeyData: Data([1]), databaseKey: Data([2])),
            ],
            senderInstallationId: "install-1"
        )
        let share = DeviceKeyShareContent(
            conversationId: "conv-2",
            inboxId: "inbox-2",
            clientId: "client-2",
            privateKeyData: Data([3]),
            databaseKey: Data([4]),
            senderInstallationId: "install-2"
        )

        let result = VaultManager.extractKeyEntries(bundles: [bundle], shares: [share])

        #expect(result.count == 2)
        let ids = Set(result.map(\.inboxId))
        #expect(ids == ["inbox-1", "inbox-2"])
    }

    @Test("Share overwrites bundle entry for same inboxId since shares are processed after bundles")
    func shareOverwritesBundleForSameInboxId() {
        let bundle = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "conv-bundle", inboxId: "inbox-1", clientId: "client-bundle", privateKeyData: Data([1]), databaseKey: Data([2])),
            ],
            senderInstallationId: "install-1"
        )
        let share = DeviceKeyShareContent(
            conversationId: "conv-share",
            inboxId: "inbox-1",
            clientId: "client-share",
            privateKeyData: Data([9]),
            databaseKey: Data([10]),
            senderInstallationId: "install-2"
        )

        let result = VaultManager.extractKeyEntries(bundles: [bundle], shares: [share])

        #expect(result.count == 1)
        #expect(result[0].clientId == "client-share")
        #expect(result[0].conversationId == "conv-share")
        #expect(result[0].privateKeyData == Data([9]))
    }

    // MARK: - extractKeyEntries: Deduplication across multiple bundles and shares

    @Test("Complex deduplication scenario with overlapping inboxIds")
    func complexDeduplication() {
        let bundle1 = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "conv-1", inboxId: "inbox-1", clientId: "client-1-v1", privateKeyData: Data([1]), databaseKey: Data([2])),
                DeviceKeyEntry(conversationId: "conv-2", inboxId: "inbox-2", clientId: "client-2-v1", privateKeyData: Data([3]), databaseKey: Data([4])),
                DeviceKeyEntry(conversationId: "conv-3", inboxId: "inbox-3", clientId: "client-3", privateKeyData: Data([5]), databaseKey: Data([6])),
            ],
            senderInstallationId: "install-1"
        )
        let bundle2 = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "conv-1-updated", inboxId: "inbox-1", clientId: "client-1-v2", privateKeyData: Data([11]), databaseKey: Data([12])),
                DeviceKeyEntry(conversationId: "conv-4", inboxId: "inbox-4", clientId: "client-4", privateKeyData: Data([7]), databaseKey: Data([8])),
            ],
            senderInstallationId: "install-2"
        )
        let share = DeviceKeyShareContent(
            conversationId: "conv-5",
            inboxId: "inbox-5",
            clientId: "client-5",
            privateKeyData: Data([13]),
            databaseKey: Data([14]),
            senderInstallationId: "install-3"
        )
        let shareOverwrite = DeviceKeyShareContent(
            conversationId: "conv-2-latest",
            inboxId: "inbox-2",
            clientId: "client-2-v2",
            privateKeyData: Data([15]),
            databaseKey: Data([16]),
            senderInstallationId: "install-3"
        )

        let result = VaultManager.extractKeyEntries(
            bundles: [bundle1, bundle2],
            shares: [share, shareOverwrite]
        )

        #expect(result.count == 5)

        let byInboxId = Dictionary(uniqueKeysWithValues: result.map { ($0.inboxId, $0) })

        let inbox1 = byInboxId["inbox-1"]
        #expect(inbox1?.clientId == "client-1-v2")
        #expect(inbox1?.privateKeyData == Data([11]))

        let inbox2 = byInboxId["inbox-2"]
        #expect(inbox2?.clientId == "client-2-v2")
        #expect(inbox2?.conversationId == "conv-2-latest")
        #expect(inbox2?.privateKeyData == Data([15]))

        let inbox3 = byInboxId["inbox-3"]
        #expect(inbox3?.clientId == "client-3")

        let inbox4 = byInboxId["inbox-4"]
        #expect(inbox4?.clientId == "client-4")

        let inbox5 = byInboxId["inbox-5"]
        #expect(inbox5?.clientId == "client-5")
    }

    // MARK: - extractKeyEntries: Bundle with empty keys array

    @Test("Bundle with empty keys array produces no entries")
    func bundleWithEmptyKeys() {
        let bundle = DeviceKeyBundleContent(
            keys: [],
            senderInstallationId: "install-1"
        )

        let result = VaultManager.extractKeyEntries(bundles: [bundle], shares: [])
        #expect(result.isEmpty)
    }

    // MARK: - extractKeyEntries: Preserves all fields

    @Test("All VaultKeyEntry fields are correctly populated from bundle")
    func bundleFieldPreservation() {
        let privateKey = Data(repeating: 0xAB, count: 32)
        let dbKey = Data(repeating: 0xCD, count: 32)

        let bundle = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(
                    conversationId: "conv-full-test",
                    inboxId: "inbox-full-test",
                    clientId: "client-full-test",
                    privateKeyData: privateKey,
                    databaseKey: dbKey
                ),
            ],
            senderInstallationId: "install-1"
        )

        let result = VaultManager.extractKeyEntries(bundles: [bundle], shares: [])

        #expect(result.count == 1)
        let entry = result[0]
        #expect(entry == VaultKeyEntry(
            inboxId: "inbox-full-test",
            clientId: "client-full-test",
            conversationId: "conv-full-test",
            privateKeyData: privateKey,
            databaseKey: dbKey
        ))
    }

    @Test("All VaultKeyEntry fields are correctly populated from share")
    func shareFieldPreservation() {
        let privateKey = Data(repeating: 0xEF, count: 32)
        let dbKey = Data(repeating: 0x01, count: 32)

        let share = DeviceKeyShareContent(
            conversationId: "conv-share-test",
            inboxId: "inbox-share-test",
            clientId: "client-share-test",
            privateKeyData: privateKey,
            databaseKey: dbKey,
            senderInstallationId: "install-1"
        )

        let result = VaultManager.extractKeyEntries(bundles: [], shares: [share])

        #expect(result.count == 1)
        let entry = result[0]
        #expect(entry == VaultKeyEntry(
            inboxId: "inbox-share-test",
            clientId: "client-share-test",
            conversationId: "conv-share-test",
            privateKeyData: privateKey,
            databaseKey: dbKey
        ))
    }

    // MARK: - extractKeyEntries: Large scale

    @Test("Handles large number of keys across bundles and shares")
    func largeScale() {
        var allKeys: [DeviceKeyEntry] = []
        for i in 0 ..< 100 {
            allKeys.append(DeviceKeyEntry(
                conversationId: "conv-\(i)",
                inboxId: "inbox-\(i)",
                clientId: "client-\(i)",
                privateKeyData: Data([UInt8(i % 256)]),
                databaseKey: Data([UInt8((i + 128) % 256)])
            ))
        }

        let bundle1 = DeviceKeyBundleContent(
            keys: Array(allKeys[0 ..< 50]),
            senderInstallationId: "install-1"
        )
        let bundle2 = DeviceKeyBundleContent(
            keys: Array(allKeys[50 ..< 100]),
            senderInstallationId: "install-2"
        )

        var shares: [DeviceKeyShareContent] = []
        for i in 100 ..< 150 {
            shares.append(DeviceKeyShareContent(
                conversationId: "conv-\(i)",
                inboxId: "inbox-\(i)",
                clientId: "client-\(i)",
                privateKeyData: Data([UInt8(i % 256)]),
                databaseKey: Data([UInt8((i + 128) % 256)]),
                senderInstallationId: "install-\(i)"
            ))
        }

        let result = VaultManager.extractKeyEntries(bundles: [bundle1, bundle2], shares: shares)
        #expect(result.count == 150)
    }

    // MARK: - extractKeyEntries: Realistic restore scenario

    @Test("Simulates a realistic vault restore with initial bundle and incremental shares")
    func realisticRestoreScenario() throws {
        let keys1 = try KeychainIdentityKeys.generate()
        let keys2 = try KeychainIdentityKeys.generate()
        let keys3 = try KeychainIdentityKeys.generate()
        let keys4 = try KeychainIdentityKeys.generate()

        let initialBundle = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(
                    conversationId: "conv-alice",
                    inboxId: "inbox-alice",
                    clientId: "client-alice",
                    privateKeyData: Data(keys1.privateKey.secp256K1.bytes),
                    databaseKey: keys1.databaseKey
                ),
                DeviceKeyEntry(
                    conversationId: "conv-bob",
                    inboxId: "inbox-bob",
                    clientId: "client-bob",
                    privateKeyData: Data(keys2.privateKey.secp256K1.bytes),
                    databaseKey: keys2.databaseKey
                ),
            ],
            senderInstallationId: "device-A",
            senderDeviceName: "iPhone"
        )

        let laterShare1 = DeviceKeyShareContent(
            conversationId: "conv-carol",
            inboxId: "inbox-carol",
            clientId: "client-carol",
            privateKeyData: Data(keys3.privateKey.secp256K1.bytes),
            databaseKey: keys3.databaseKey,
            senderInstallationId: "device-A",
            senderDeviceName: "iPhone"
        )

        let laterShare2 = DeviceKeyShareContent(
            conversationId: "conv-dave",
            inboxId: "inbox-dave",
            clientId: "client-dave",
            privateKeyData: Data(keys4.privateKey.secp256K1.bytes),
            databaseKey: keys4.databaseKey,
            senderInstallationId: "device-A",
            senderDeviceName: "iPhone"
        )

        let result = VaultManager.extractKeyEntries(
            bundles: [initialBundle],
            shares: [laterShare1, laterShare2]
        )

        #expect(result.count == 4)

        let byInboxId = Dictionary(uniqueKeysWithValues: result.map { ($0.inboxId, $0) })
        #expect(byInboxId["inbox-alice"] != nil)
        #expect(byInboxId["inbox-bob"] != nil)
        #expect(byInboxId["inbox-carol"] != nil)
        #expect(byInboxId["inbox-dave"] != nil)

        let aliceEntry = byInboxId["inbox-alice"]
        #expect(aliceEntry?.privateKeyData == Data(keys1.privateKey.secp256K1.bytes))
        #expect(aliceEntry?.databaseKey == keys1.databaseKey)

        let carolEntry = byInboxId["inbox-carol"]
        #expect(carolEntry?.privateKeyData == Data(keys3.privateKey.secp256K1.bytes))
        #expect(carolEntry?.databaseKey == keys3.databaseKey)
    }

    @Test("Simulates restore after re-pairing where second bundle replaces first")
    func restoreAfterRePairing() throws {
        let oldKeys = try KeychainIdentityKeys.generate()
        let newKeys = try KeychainIdentityKeys.generate()
        let unchangedKeys = try KeychainIdentityKeys.generate()

        let firstBundle = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "conv-a", inboxId: "inbox-a", clientId: "client-a-old", privateKeyData: Data(oldKeys.privateKey.secp256K1.bytes), databaseKey: oldKeys.databaseKey),
                DeviceKeyEntry(conversationId: "conv-b", inboxId: "inbox-b", clientId: "client-b", privateKeyData: Data(unchangedKeys.privateKey.secp256K1.bytes), databaseKey: unchangedKeys.databaseKey),
            ],
            senderInstallationId: "device-A"
        )

        let secondBundle = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "conv-a", inboxId: "inbox-a", clientId: "client-a-new", privateKeyData: Data(newKeys.privateKey.secp256K1.bytes), databaseKey: newKeys.databaseKey),
                DeviceKeyEntry(conversationId: "conv-b", inboxId: "inbox-b", clientId: "client-b", privateKeyData: Data(unchangedKeys.privateKey.secp256K1.bytes), databaseKey: unchangedKeys.databaseKey),
            ],
            senderInstallationId: "device-B"
        )

        let result = VaultManager.extractKeyEntries(bundles: [firstBundle, secondBundle], shares: [])

        #expect(result.count == 2)

        let byInboxId = Dictionary(uniqueKeysWithValues: result.map { ($0.inboxId, $0) })

        let inboxA = byInboxId["inbox-a"]
        #expect(inboxA?.clientId == "client-a-new")
        #expect(inboxA?.privateKeyData == Data(newKeys.privateKey.secp256K1.bytes))

        let inboxB = byInboxId["inbox-b"]
        #expect(inboxB?.privateKeyData == Data(unchangedKeys.privateKey.secp256K1.bytes))
    }
}

@Suite("VaultKeyEntry Tests")
struct VaultKeyEntryTests {
    @Test("Equatable: identical entries are equal")
    func equatableIdentical() {
        let a = VaultKeyEntry(inboxId: "i", clientId: "c", conversationId: "conv", privateKeyData: Data([1]), databaseKey: Data([2]))
        let b = VaultKeyEntry(inboxId: "i", clientId: "c", conversationId: "conv", privateKeyData: Data([1]), databaseKey: Data([2]))
        #expect(a == b)
    }

    @Test("Equatable: different inboxId")
    func equatableDifferentInboxId() {
        let a = VaultKeyEntry(inboxId: "i1", clientId: "c", conversationId: "conv", privateKeyData: Data([1]), databaseKey: Data([2]))
        let b = VaultKeyEntry(inboxId: "i2", clientId: "c", conversationId: "conv", privateKeyData: Data([1]), databaseKey: Data([2]))
        #expect(a != b)
    }

    @Test("Equatable: different privateKeyData")
    func equatableDifferentPrivateKey() {
        let a = VaultKeyEntry(inboxId: "i", clientId: "c", conversationId: "conv", privateKeyData: Data([1]), databaseKey: Data([2]))
        let b = VaultKeyEntry(inboxId: "i", clientId: "c", conversationId: "conv", privateKeyData: Data([9]), databaseKey: Data([2]))
        #expect(a != b)
    }

    @Test("Equatable: different databaseKey")
    func equatableDifferentDatabaseKey() {
        let a = VaultKeyEntry(inboxId: "i", clientId: "c", conversationId: "conv", privateKeyData: Data([1]), databaseKey: Data([2]))
        let b = VaultKeyEntry(inboxId: "i", clientId: "c", conversationId: "conv", privateKeyData: Data([1]), databaseKey: Data([9]))
        #expect(a != b)
    }

    @Test("Sendable conformance compiles")
    func sendable() async {
        let entry = VaultKeyEntry(inboxId: "i", clientId: "c", conversationId: "conv", privateKeyData: Data([1]), databaseKey: Data([2]))
        let task = Task { entry }
        let result = await task.value
        #expect(result == entry)
    }
}
