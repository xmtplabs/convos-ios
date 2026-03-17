@testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

// MARK: - Mock archive importer

final class MockRestoreArchiveImporter: RestoreArchiveImporter, @unchecked Sendable {
    var importedArchives: [(inboxId: String, path: String)] = []
    var failingInboxIds: Set<String> = []

    func importConversationArchive(inboxId: String, path: String, encryptionKey: Data) async throws {
        if failingInboxIds.contains(inboxId) {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "simulated import failure"])
        }
        importedArchives.append((inboxId: inboxId, path: path))
    }
}

// MARK: - Mock vault service for restore

final class MockRestoreVaultService: VaultServiceProtocol, @unchecked Sendable {
    var importedArchivePath: URL?
    var keyEntriesToReturn: [VaultKeyEntry] = []

    func startVault(signingKey: any SigningKey, options: XMTPiOS.ClientOptions) async throws {}
    func stopVault() async {}
    func pauseVault() async {}
    func resumeVault() async {}
    func unpairSelf() async throws {}
    func broadcastConversationDeleted(inboxId: String, clientId: String) async {}

    func createArchive(at path: URL, encryptionKey: Data) async throws {
        try Data("vault-archive".utf8).write(to: path)
    }

    @discardableResult
    func importArchive(from path: URL, encryptionKey: Data) async throws -> [VaultKeyEntry] {
        importedArchivePath = path
        return keyEntriesToReturn
    }
}

// MARK: - Tests

@Suite("RestoreManager Tests", .serialized)
struct RestoreManagerTests {
    @Test("Full restore flow decrypts bundle, imports vault, saves keys, replaces DB")
    func testFullRestoreFlow() async throws {
        let fixtures = TestFixtures()
        let identityStore = MockKeychainIdentityStore()
        let (vaultKeyStore, vaultEncryptionKey) = try await seedVaultKey(store: identityStore)
        let vaultService = MockRestoreVaultService()
        let archiveImporter = MockRestoreArchiveImporter()

        let keyEntries: [VaultKeyEntry] = [
            .init(inboxId: "conv-1", clientId: "client-1", conversationId: "group-1",
                  privateKeyData: Data(repeating: 0x01, count: 32), databaseKey: Data(repeating: 0x02, count: 32)),
            .init(inboxId: "conv-2", clientId: "client-2", conversationId: "group-2",
                  privateKeyData: Data(repeating: 0x03, count: 32), databaseKey: Data(repeating: 0x04, count: 32)),
        ]
        vaultService.keyEntriesToReturn = keyEntries

        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)
        _ = try await inboxWriter.save(inboxId: "old-inbox", clientId: "old-client")

        let bundleURL = try await createTestBundle(
            encryptionKey: vaultEncryptionKey,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let manager = RestoreManager(
            vaultKeyStore: vaultKeyStore,
            vaultService: vaultService,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager,
            archiveImporter: archiveImporter,
            environment: .tests
        )

        try await manager.restoreFromBackup(bundleURL: bundleURL)

        let finalState = await manager.state
        guard case .completed(_, let failedKeyCount) = finalState else {
            Issue.record("Expected completed state, got \(finalState)")
            try? await fixtures.cleanup()
            return
        }

        #expect(failedKeyCount == 0)
        #expect(vaultService.importedArchivePath != nil)

        let savedConv1 = try? await identityStore.identity(for: "conv-1")
        #expect(savedConv1 != nil)
        #expect(savedConv1?.clientId == "client-1")

        let savedConv2 = try? await identityStore.identity(for: "conv-2")
        #expect(savedConv2 != nil)

        try? await fixtures.cleanup()
    }

    @Test("Restore replaces GRDB database with backup copy")
    func testRestoreReplacesDatabase() async throws {
        let fixtures = TestFixtures()
        let identityStore = MockKeychainIdentityStore()
        let (vaultKeyStore, vaultEncryptionKey) = try await seedVaultKey(store: identityStore)
        let vaultService = MockRestoreVaultService()
        let archiveImporter = MockRestoreArchiveImporter()

        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)
        _ = try await inboxWriter.save(inboxId: "backup-inbox", clientId: "backup-client")

        let bundleURL = try await createTestBundle(
            encryptionKey: vaultEncryptionKey,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        _ = try await inboxWriter.save(inboxId: "post-backup-inbox", clientId: "post-backup-client")
        let preRestoreCount = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchCount(db)
        }
        #expect(preRestoreCount == 2)

        let manager = RestoreManager(
            vaultKeyStore: vaultKeyStore,
            vaultService: vaultService,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager,
            archiveImporter: archiveImporter,
            environment: .tests
        )

        try await manager.restoreFromBackup(bundleURL: bundleURL)

        let postRestoreCount = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchCount(db)
        }
        #expect(postRestoreCount == 1)

        let restoredInbox = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: "backup-inbox")
        }
        #expect(restoredInbox != nil)

        try? await fixtures.cleanup()
    }

    @Test("Conversation archive import failure is non-fatal")
    func testPartialConversationImportFailure() async throws {
        let fixtures = TestFixtures()
        let identityStore = MockKeychainIdentityStore()
        let vaultStore = MockKeychainIdentityStore()
        let (vaultKeyStore, vaultEncryptionKey) = try await seedVaultKey(store: vaultStore)
        let vaultService = MockRestoreVaultService()
        let archiveImporter = MockRestoreArchiveImporter()

        archiveImporter.failingInboxIds = ["conv-fail"]

        let bundleURL = try await createTestBundleWithConversations(
            encryptionKey: vaultEncryptionKey,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager,
            conversationInboxIds: ["conv-ok", "conv-fail"]
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let manager = RestoreManager(
            vaultKeyStore: vaultKeyStore,
            vaultService: vaultService,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager,
            archiveImporter: archiveImporter,
            environment: .tests
        )

        try await manager.restoreFromBackup(bundleURL: bundleURL)

        let finalState = await manager.state
        guard case .completed = finalState else {
            Issue.record("Expected completed state, got \(finalState)")
            try? await fixtures.cleanup()
            return
        }

        #expect(archiveImporter.importedArchives.count == 1)
        #expect(archiveImporter.importedArchives.first?.inboxId == "conv-ok")

        try? await fixtures.cleanup()
    }

    @Test("Restore fails with clear error on missing vault archive")
    func testMissingVaultArchive() async throws {
        let fixtures = TestFixtures()
        let identityStore = MockKeychainIdentityStore()
        let (vaultKeyStore, vaultEncryptionKey) = try await seedVaultKey(store: identityStore)
        let vaultService = MockRestoreVaultService()
        let archiveImporter = MockRestoreArchiveImporter()

        let bundleURL = try await createBundleWithoutVaultArchive(
            encryptionKey: vaultEncryptionKey,
            databaseManager: fixtures.databaseManager
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let manager = RestoreManager(
            vaultKeyStore: vaultKeyStore,
            vaultService: vaultService,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager,
            archiveImporter: archiveImporter,
            environment: .tests
        )

        await #expect(throws: (any Error).self) {
            try await manager.restoreFromBackup(bundleURL: bundleURL)
        }

        let finalState = await manager.state
        guard case .failed = finalState else {
            Issue.record("Expected failed state, got \(finalState)")
            try? await fixtures.cleanup()
            return
        }

        try? await fixtures.cleanup()
    }

    @Test("Restore detection finds available backup")
    func testFindAvailableBackup() throws {
        let backupsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("test-device", isDirectory: true)
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: backupsDir.deletingLastPathComponent()) }

        let metadata = BackupBundleMetadata(
            deviceId: "test-device",
            deviceName: "Test iPhone",
            osString: "ios",
            inboxCount: 3
        )
        try BackupBundleMetadata.write(metadata, to: backupsDir)
        try Data("encrypted-bundle".utf8).write(to: backupsDir.appendingPathComponent("backup-latest.encrypted"))

        let result = RestoreManager.findNewestBackup(in: backupsDir.deletingLastPathComponent())
        #expect(result != nil)
        #expect(result?.metadata.deviceName == "Test iPhone")
        #expect(result?.metadata.inboxCount == 3)
    }

    @Test("Restore detection returns nil when no backup exists")
    func testFindAvailableBackupReturnsNil() {
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-backups-\(UUID().uuidString)")
        let result = RestoreManager.findNewestBackup(in: emptyDir)
        #expect(result == nil)
    }

    @Test("RestoreState progresses through expected phases")
    func testStateProgression() async throws {
        let fixtures = TestFixtures()
        let identityStore = MockKeychainIdentityStore()
        let (vaultKeyStore, vaultEncryptionKey) = try await seedVaultKey(store: identityStore)
        let vaultService = MockRestoreVaultService()
        let archiveImporter = MockRestoreArchiveImporter()

        let bundleURL = try await createTestBundle(
            encryptionKey: vaultEncryptionKey,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let manager = RestoreManager(
            vaultKeyStore: vaultKeyStore,
            vaultService: vaultService,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager,
            archiveImporter: archiveImporter,
            environment: .tests
        )

        let initialState = await manager.state
        #expect(initialState == .idle)

        try await manager.restoreFromBackup(bundleURL: bundleURL)

        let finalState = await manager.state
        guard case .completed = finalState else {
            Issue.record("Expected completed state, got \(finalState)")
            try? await fixtures.cleanup()
            return
        }

        try? await fixtures.cleanup()
    }

    // MARK: - Helpers

    private func seedVaultKey(store: MockKeychainIdentityStore) async throws -> (VaultKeyStore, Data) {
        let keys = try await store.generateKeys()
        _ = try await store.save(inboxId: "vault-inbox", clientId: "vault-client", keys: keys)
        return (VaultKeyStore(store: store), keys.databaseKey)
    }

    private func createTestBundle(
        encryptionKey: Data,
        identityStore: MockKeychainIdentityStore,
        databaseManager: MockDatabaseManager
    ) async throws -> URL {

        let stagingDir = try BackupBundle.createStagingDirectory()
        defer { BackupBundle.cleanup(directory: stagingDir) }

        try Data("vault-archive-data".utf8).write(to: BackupBundle.vaultArchivePath(in: stagingDir))

        let destPath = BackupBundle.databasePath(in: stagingDir)
        let destQueue = try DatabaseQueue(path: destPath.path)
        try databaseManager.dbReader.backup(to: destQueue)

        let metadata = BackupBundleMetadata(
            deviceId: "test-device",
            deviceName: "Test Device",
            osString: "ios",
            inboxCount: 0
        )
        try BackupBundleMetadata.write(metadata, to: stagingDir)

        let bundleData = try BackupBundle.pack(directory: stagingDir, encryptionKey: encryptionKey)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-bundle-\(UUID().uuidString).encrypted")
        try bundleData.write(to: bundleURL)
        return bundleURL
    }

    private func createTestBundleWithConversations(
        encryptionKey: Data,
        identityStore: MockKeychainIdentityStore,
        databaseManager: MockDatabaseManager,
        conversationInboxIds: [String]
    ) async throws -> URL {

        let stagingDir = try BackupBundle.createStagingDirectory()
        defer { BackupBundle.cleanup(directory: stagingDir) }

        try Data("vault-archive-data".utf8).write(to: BackupBundle.vaultArchivePath(in: stagingDir))

        for inboxId in conversationInboxIds {
            let keys = try await identityStore.generateKeys()
            _ = try await identityStore.save(inboxId: inboxId, clientId: "client-\(inboxId)", keys: keys)

            let archivePath = BackupBundle.conversationArchivePath(inboxId: inboxId, in: stagingDir)
            try Data("conversation-\(inboxId)".utf8).write(to: archivePath)
        }

        let destPath = BackupBundle.databasePath(in: stagingDir)
        let destQueue = try DatabaseQueue(path: destPath.path)
        try databaseManager.dbReader.backup(to: destQueue)

        let metadata = BackupBundleMetadata(
            deviceId: "test-device",
            deviceName: "Test Device",
            osString: "ios",
            inboxCount: conversationInboxIds.count
        )
        try BackupBundleMetadata.write(metadata, to: stagingDir)

        let bundleData = try BackupBundle.pack(directory: stagingDir, encryptionKey: encryptionKey)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-bundle-\(UUID().uuidString).encrypted")
        try bundleData.write(to: bundleURL)
        return bundleURL
    }

    private func createBundleWithoutVaultArchive(
        encryptionKey: Data,
        databaseManager: MockDatabaseManager
    ) async throws -> URL {

        let stagingDir = try BackupBundle.createStagingDirectory()
        defer { BackupBundle.cleanup(directory: stagingDir) }

        let destPath = BackupBundle.databasePath(in: stagingDir)
        let destQueue = try DatabaseQueue(path: destPath.path)
        try databaseManager.dbReader.backup(to: destQueue)

        let metadata = BackupBundleMetadata(
            deviceId: "test-device",
            deviceName: "Test Device",
            osString: "ios",
            inboxCount: 0
        )
        try BackupBundleMetadata.write(metadata, to: stagingDir)

        let bundleData = try BackupBundle.pack(directory: stagingDir, encryptionKey: encryptionKey)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-bundle-\(UUID().uuidString).encrypted")
        try bundleData.write(to: bundleURL)
        return bundleURL
    }
}
