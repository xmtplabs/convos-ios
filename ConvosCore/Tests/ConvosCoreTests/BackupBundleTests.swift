@testable import ConvosCore
import Foundation
import GRDB
import Testing

// MARK: - Mock archive provider

actor MockBackupArchiveProvider: BackupArchiveProvider {
    var vaultArchiveCalls: [(URL, Data)] = []
    var conversationArchiveCalls: [(String, String, Data)] = []
    var failingInboxIds: Set<String> = []

    func setFailingInboxIds(_ ids: Set<String>) {
        failingInboxIds = ids
    }

    func broadcastKeysToVault() async throws {}

    func createVaultArchive(at path: URL, encryptionKey: Data) async throws {
        vaultArchiveCalls.append((path, encryptionKey))
        try Data("vault-archive-data".utf8).write(to: path)
    }

    func createConversationArchive(inboxId: String, at path: String, encryptionKey: Data) async throws {
        if failingInboxIds.contains(inboxId) {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "simulated failure"])
        }
        conversationArchiveCalls.append((inboxId, path, encryptionKey))
        try Data("conversation-\(inboxId)".utf8).write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Metadata Tests

@Suite("BackupBundleMetadata Tests")
struct BackupBundleMetadataTests {
    @Test("Metadata round-trips through JSON")
    func testMetadataRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let metadata = BackupBundleMetadata(
            version: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            deviceId: "test-device-id",
            deviceName: "Test iPhone",
            osString: "ios",
            inboxCount: 5
        )

        try BackupBundleMetadata.write(metadata, to: tempDir)
        let loaded = try BackupBundleMetadata.read(from: tempDir)

        #expect(loaded.version == 1)
        #expect(loaded.deviceId == "test-device-id")
        #expect(loaded.deviceName == "Test iPhone")
        #expect(loaded.osString == "ios")
        #expect(loaded.inboxCount == 5)
        #expect(loaded.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Metadata defaults to version 1")
    func testMetadataDefaultVersion() {
        let metadata = BackupBundleMetadata(
            deviceId: "id",
            deviceName: "name",
            osString: "ios",
            inboxCount: 0
        )
        #expect(metadata.version == 1)
    }
}

// MARK: - Crypto Tests

@Suite("BackupBundleCrypto Tests")
struct BackupBundleCryptoTests {
    @Test("Encrypt and decrypt round-trips data")
    func testEncryptDecryptRoundTrip() throws {
        let key = Data(repeating: 0xAB, count: 32)
        let plaintext = Data("Hello, backup world!".utf8)

        let encrypted = try BackupBundleCrypto.encrypt(data: plaintext, key: key)
        #expect(encrypted != plaintext)

        let decrypted = try BackupBundleCrypto.decrypt(data: encrypted, key: key)
        #expect(decrypted == plaintext)
    }

    @Test("Decrypt with wrong key fails")
    func testDecryptWrongKey() throws {
        let key1 = Data(repeating: 0xAB, count: 32)
        let key2 = Data(repeating: 0xCD, count: 32)
        let plaintext = Data("secret".utf8)

        let encrypted = try BackupBundleCrypto.encrypt(data: plaintext, key: key1)
        #expect(throws: BackupBundleCrypto.CryptoError.self) {
            _ = try BackupBundleCrypto.decrypt(data: encrypted, key: key2)
        }
    }

    @Test("Invalid key length throws")
    func testInvalidKeyLength() {
        let shortKey = Data(repeating: 0xAB, count: 16)
        let plaintext = Data("test".utf8)

        #expect(throws: BackupBundleCrypto.CryptoError.self) {
            _ = try BackupBundleCrypto.encrypt(data: plaintext, key: shortKey)
        }
        #expect(throws: BackupBundleCrypto.CryptoError.self) {
            _ = try BackupBundleCrypto.decrypt(data: plaintext, key: shortKey)
        }
    }

    @Test("Encrypts empty data")
    func testEncryptEmptyData() throws {
        let key = Data(repeating: 0xAB, count: 32)
        let encrypted = try BackupBundleCrypto.encrypt(data: Data(), key: key)
        let decrypted = try BackupBundleCrypto.decrypt(data: encrypted, key: key)
        #expect(decrypted == Data())
    }

    @Test("Encrypts large data")
    func testEncryptLargeData() throws {
        let key = Data(repeating: 0xAB, count: 32)
        let plaintext = Data(repeating: 0xFF, count: 1_000_000)
        let encrypted = try BackupBundleCrypto.encrypt(data: plaintext, key: key)
        let decrypted = try BackupBundleCrypto.decrypt(data: encrypted, key: key)
        #expect(decrypted == plaintext)
    }
}

// MARK: - Bundle Tar Tests

@Suite("BackupBundle Tar Tests")
struct BackupBundleTarTests {
    @Test("Tar and untar round-trips directory contents")
    func testTarRoundTrip() throws {
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tar-source-\(UUID().uuidString)")
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tar-dest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        try Data("file-a".utf8).write(to: sourceDir.appendingPathComponent("a.txt"))
        let subDir = sourceDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try Data("file-b".utf8).write(to: subDir.appendingPathComponent("b.bin"))

        let tarData = try BackupBundle.tarDirectory(sourceDir)
        try BackupBundle.untarData(tarData, to: destDir)

        let aData = try Data(contentsOf: destDir.appendingPathComponent("a.txt"))
        #expect(String(data: aData, encoding: .utf8) == "file-a")

        let bData = try Data(contentsOf: destDir.appendingPathComponent("sub/b.bin"))
        #expect(String(data: bData, encoding: .utf8) == "file-b")
    }

    @Test("Pack and unpack round-trips with encryption")
    func testPackUnpackRoundTrip() throws {
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-source-\(UUID().uuidString)")
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-dest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        try Data("hello".utf8).write(to: sourceDir.appendingPathComponent("test.txt"))

        let key = Data(repeating: 0x42, count: 32)
        let packed = try BackupBundle.pack(directory: sourceDir, encryptionKey: key)
        try BackupBundle.unpack(data: packed, encryptionKey: key, to: destDir)

        let recovered = try Data(contentsOf: destDir.appendingPathComponent("test.txt"))
        #expect(String(data: recovered, encoding: .utf8) == "hello")
    }

    @Test("Unpack with wrong key fails")
    func testUnpackWrongKey() throws {
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-wrongkey-\(UUID().uuidString)")
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-wrongkey-dest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        try Data("secret".utf8).write(to: sourceDir.appendingPathComponent("s.txt"))

        let key1 = Data(repeating: 0x42, count: 32)
        let key2 = Data(repeating: 0x99, count: 32)
        let packed = try BackupBundle.pack(directory: sourceDir, encryptionKey: key1)

        #expect(throws: (any Error).self) {
            try BackupBundle.unpack(data: packed, encryptionKey: key2, to: destDir)
        }
    }

    @Test("Untar rejects path traversal attempts")
    func testUntarRejectsPathTraversal() throws {
        var maliciousArchive = Data()

        let maliciousPath = Data("../../etc/evil.txt".utf8)
        var pathLength = UInt32(maliciousPath.count).bigEndian
        maliciousArchive.append(Data(bytes: &pathLength, count: 4))
        maliciousArchive.append(maliciousPath)

        let fileData = Data("malicious".utf8)
        var fileLength = UInt64(fileData.count).bigEndian
        maliciousArchive.append(Data(bytes: &fileLength, count: 8))
        maliciousArchive.append(fileData)

        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("traversal-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        #expect(throws: BackupBundle.BundleError.self) {
            try BackupBundle.untarData(maliciousArchive, to: destDir)
        }
    }

    @Test("Empty directory tars to empty data")
    func testEmptyDirectoryTar() throws {
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tar-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        let tarData = try BackupBundle.tarDirectory(sourceDir)
        #expect(tarData.isEmpty)
    }
}

// MARK: - BackupManager Tests

@Suite("BackupManager Tests", .serialized)
struct BackupManagerTests {
    @Test("createBackup produces encrypted bundle with metadata")
    func testCreateBackupProducesBundle() async throws {
        let fixtures = TestFixtures()
        let archiveProvider = MockBackupArchiveProvider()
        let identityStore = MockKeychainIdentityStore()
        let vaultKeyStore = try await seedVaultKey(store: identityStore)

        try await seedConversationIdentity(store: identityStore, inboxId: "inbox-1", clientId: "client-1")
        try await seedConversationIdentity(store: identityStore, inboxId: "inbox-2", clientId: "client-2")

        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)
        _ = try await inboxWriter.save(inboxId: "inbox-1", clientId: "client-1")
        _ = try await inboxWriter.save(inboxId: "inbox-2", clientId: "client-2")
        try await seedConversation(
            databaseWriter: fixtures.databaseManager.dbWriter,
            inboxId: "inbox-1",
            clientId: "client-1",
            isUnused: false
        )
        try await seedConversation(
            databaseWriter: fixtures.databaseManager.dbWriter,
            inboxId: "inbox-2",
            clientId: "client-2",
            isUnused: false
        )

        let manager = BackupManager(
            vaultKeyStore: vaultKeyStore,
            archiveProvider: archiveProvider,
            identityStore: identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: .tests
        )

        let outputURL = try await manager.createBackup()

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(outputURL.lastPathComponent == "backup-latest.encrypted")

        let backupDir = outputURL.deletingLastPathComponent()
        #expect(BackupBundleMetadata.exists(in: backupDir))
        let sidecarMetadata = try BackupBundleMetadata.read(from: backupDir)
        #expect(sidecarMetadata.version == 1)
        #expect(sidecarMetadata.inboxCount == 2)

        #expect(await archiveProvider.vaultArchiveCalls.count == 1)
        #expect(await archiveProvider.conversationArchiveCalls.count == 2)

        try? FileManager.default.removeItem(at: backupDir)
        try? await fixtures.cleanup()
    }

    @Test("Single conversation failure does not fail whole backup")
    func testPartialConversationFailure() async throws {
        let fixtures = TestFixtures()
        let archiveProvider = MockBackupArchiveProvider()
        let identityStore = MockKeychainIdentityStore()
        let vaultKeyStore = try await seedVaultKey(store: identityStore)

        try await seedConversationIdentity(store: identityStore, inboxId: "inbox-ok", clientId: "client-ok")
        try await seedConversationIdentity(store: identityStore, inboxId: "inbox-fail", clientId: "client-fail")

        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)
        _ = try await inboxWriter.save(inboxId: "inbox-ok", clientId: "client-ok")
        _ = try await inboxWriter.save(inboxId: "inbox-fail", clientId: "client-fail")
        try await seedConversation(
            databaseWriter: fixtures.databaseManager.dbWriter,
            inboxId: "inbox-ok",
            clientId: "client-ok",
            isUnused: false
        )
        try await seedConversation(
            databaseWriter: fixtures.databaseManager.dbWriter,
            inboxId: "inbox-fail",
            clientId: "client-fail",
            isUnused: false
        )

        await archiveProvider.setFailingInboxIds(["inbox-fail"])

        let manager = BackupManager(
            vaultKeyStore: vaultKeyStore,
            archiveProvider: archiveProvider,
            identityStore: identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: .tests
        )

        let outputURL = try await manager.createBackup()
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        #expect(await archiveProvider.vaultArchiveCalls.count == 1)

        try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
        try? await fixtures.cleanup()
    }

    @Test("Bundle is decryptable with vault key")
    func testBundleDecryptableWithVaultKey() async throws {
        let fixtures = TestFixtures()
        let archiveProvider = MockBackupArchiveProvider()
        let identityStore = MockKeychainIdentityStore()
        let vaultKeyStore = try await seedVaultKey(store: identityStore)

        let manager = BackupManager(
            vaultKeyStore: vaultKeyStore,
            archiveProvider: archiveProvider,
            identityStore: identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: .tests
        )

        let outputURL = try await manager.createBackup()

        let vaultIdentity = try await vaultKeyStore.loadAny()
        let bundleData = try Data(contentsOf: outputURL)

        let unpackDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unpack-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: unpackDir)
            try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
        }

        try BackupBundle.unpack(data: bundleData, encryptionKey: vaultIdentity.keys.databaseKey, to: unpackDir)

        let metadata = try BackupBundleMetadata.read(from: unpackDir)
        #expect(metadata.version == 1)

        let vaultArchiveExists = FileManager.default.fileExists(
            atPath: BackupBundle.vaultArchivePath(in: unpackDir).path
        )
        #expect(vaultArchiveExists)

        let dbExists = FileManager.default.fileExists(
            atPath: BackupBundle.databasePath(in: unpackDir).path
        )
        #expect(dbExists)

        try? await fixtures.cleanup()
    }

    @Test("Backup includes GRDB database copy")
    func testBackupIncludesDatabase() async throws {
        let fixtures = TestFixtures()
        let archiveProvider = MockBackupArchiveProvider()
        let identityStore = MockKeychainIdentityStore()
        let vaultKeyStore = try await seedVaultKey(store: identityStore)

        try await seedConversationIdentity(store: identityStore, inboxId: "inbox-db-test", clientId: "client-db-test")

        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)
        _ = try await inboxWriter.save(inboxId: "inbox-db-test", clientId: "client-db-test")

        let manager = BackupManager(
            vaultKeyStore: vaultKeyStore,
            archiveProvider: archiveProvider,
            identityStore: identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: .tests
        )

        let outputURL = try await manager.createBackup()

        let vaultIdentity = try await vaultKeyStore.loadAny()
        let bundleData = try Data(contentsOf: outputURL)
        let unpackDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("db-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: unpackDir)
            try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
        }

        try BackupBundle.unpack(data: bundleData, encryptionKey: vaultIdentity.keys.databaseKey, to: unpackDir)

        let restoredDbPath = BackupBundle.databasePath(in: unpackDir)
        let restoredQueue = try DatabaseQueue(path: restoredDbPath.path)
        let inboxCount = try await restoredQueue.read { db in
            try DBInbox.fetchCount(db)
        }
        #expect(inboxCount == 1)

        try? await fixtures.cleanup()
    }

    @Test("Backup excludes unused conversation inboxes from metadata and archives")
    func testBackupExcludesUnusedConversationInboxes() async throws {
        let fixtures = TestFixtures()
        let archiveProvider = MockBackupArchiveProvider()
        let identityStore = MockKeychainIdentityStore()
        let vaultKeyStore = try await seedVaultKey(store: identityStore)

        try await seedConversationIdentity(store: identityStore, inboxId: "inbox-active", clientId: "client-active")
        try await seedConversationIdentity(store: identityStore, inboxId: "inbox-unused", clientId: "client-unused")

        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)
        _ = try await inboxWriter.save(inboxId: "inbox-active", clientId: "client-active")
        _ = try await inboxWriter.save(inboxId: "inbox-unused", clientId: "client-unused")

        try await seedConversation(
            databaseWriter: fixtures.databaseManager.dbWriter,
            inboxId: "inbox-active",
            clientId: "client-active",
            isUnused: false
        )
        try await seedConversation(
            databaseWriter: fixtures.databaseManager.dbWriter,
            inboxId: "inbox-unused",
            clientId: "client-unused",
            isUnused: true
        )

        let manager = BackupManager(
            vaultKeyStore: vaultKeyStore,
            archiveProvider: archiveProvider,
            identityStore: identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: .tests
        )

        let outputURL = try await manager.createBackup()
        defer {
            try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
        }

        let sidecarMetadata = try BackupBundleMetadata.read(from: outputURL.deletingLastPathComponent())
        #expect(sidecarMetadata.inboxCount == 1)
        #expect(await archiveProvider.conversationArchiveCalls.count == 1)
        #expect(await archiveProvider.conversationArchiveCalls.first?.0 == "inbox-active")

        try? await fixtures.cleanup()
    }

    @Test("Backup with no conversation inboxes succeeds")
    func testBackupWithNoConversations() async throws {
        let fixtures = TestFixtures()
        let archiveProvider = MockBackupArchiveProvider()
        let identityStore = MockKeychainIdentityStore()
        let vaultKeyStore = try await seedVaultKey(store: identityStore)

        let manager = BackupManager(
            vaultKeyStore: vaultKeyStore,
            archiveProvider: archiveProvider,
            identityStore: identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: .tests
        )

        let outputURL = try await manager.createBackup()
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        #expect(await archiveProvider.vaultArchiveCalls.count == 1)
        #expect(await archiveProvider.conversationArchiveCalls.count == 0)

        try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
        try? await fixtures.cleanup()
    }

    // MARK: - Helpers

    private func seedVaultKey(store: MockKeychainIdentityStore) async throws -> VaultKeyStore {
        let keys = try await store.generateKeys()
        _ = try await store.save(inboxId: "vault-inbox", clientId: "vault-client", keys: keys)
        return VaultKeyStore(store: store)
    }

    private func seedConversationIdentity(
        store: MockKeychainIdentityStore,
        inboxId: String,
        clientId: String
    ) async throws {
        let keys = try await store.generateKeys()
        _ = try await store.save(inboxId: inboxId, clientId: clientId, keys: keys)
    }

    private func seedConversation(
        databaseWriter: any DatabaseWriter,
        inboxId: String,
        clientId: String,
        isUnused: Bool
    ) async throws {
        let conversation = DBConversation(
            id: "conversation-\(inboxId)",
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: "client-conversation-\(inboxId)",
            inviteTag: "invite-\(inboxId)",
            creatorId: inboxId,
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            imageLastRenewed: nil,
            isUnused: isUnused
        )

        try await databaseWriter.write { db in
            try conversation.save(db)
        }
    }
}
