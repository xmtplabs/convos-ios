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

final class MockVaultArchiveImporter: VaultArchiveImporter, @unchecked Sendable {
    var keyEntriesToReturn: [VaultKeyEntry] = []

    func importVaultArchive(from path: URL, encryptionKey: Data) async throws -> [VaultKeyEntry] {
        keyEntriesToReturn
    }
}

actor MockRestoreLifecycleController: RestoreLifecycleControlling {
    private(set) var prepareCallCount: Int = 0
    private(set) var finishCallCount: Int = 0

    func prepareForRestore() {
        prepareCallCount += 1
    }

    func finishRestore() {
        finishCallCount += 1
    }
}

// MARK: - Tests

@Suite("RestoreManager Tests", .serialized)
struct RestoreManagerTests {
    @Test("Full restore flow decrypts bundle, replaces DB, reaches completed state")
    func testFullRestoreFlow() async throws {
        let fixtures = TestFixtures()
        let identityStore = MockKeychainIdentityStore()
        let (vaultKeyStore, vaultEncryptionKey) = try await seedVaultKey(store: identityStore)
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

        let vaultImporter = MockVaultArchiveImporter()
        let manager = RestoreManager(
            vaultKeyStore: vaultKeyStore,
            vaultArchiveImporter: vaultImporter,
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

        let restoredInbox = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: "backup-inbox")
        }
        #expect(restoredInbox != nil)

        let postBackupInbox = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: "post-backup-inbox")
        }
        #expect(postBackupInbox == nil)

        try? await fixtures.cleanup()
    }

    @Test("Restore replaces GRDB database with backup copy")
    func testRestoreReplacesDatabase() async throws {
        let fixtures = TestFixtures()
        let identityStore = MockKeychainIdentityStore()
        let (vaultKeyStore, vaultEncryptionKey) = try await seedVaultKey(store: identityStore)
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

        let vaultImporter = MockVaultArchiveImporter()
        let manager = RestoreManager(
            vaultKeyStore: vaultKeyStore,
            vaultArchiveImporter: vaultImporter,
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
        let archiveImporter = MockRestoreArchiveImporter()

        archiveImporter.failingInboxIds = ["conv-fail"]

        let bundleURL = try await createTestBundleWithConversations(
            encryptionKey: vaultEncryptionKey,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager,
            conversationInboxIds: ["conv-ok", "conv-fail"]
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let vaultImporter = MockVaultArchiveImporter()
        let manager = RestoreManager(
            vaultKeyStore: vaultKeyStore,
            vaultArchiveImporter: vaultImporter,
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

    @Test("Restore completes even without vault archive in bundle")
    func testMissingVaultArchiveIsNonFatal() async throws {
        let fixtures = TestFixtures()
        let identityStore = MockKeychainIdentityStore()
        let (vaultKeyStore, vaultEncryptionKey) = try await seedVaultKey(store: identityStore)
        let archiveImporter = MockRestoreArchiveImporter()

        let bundleURL = try await createBundleWithoutVaultArchive(
            encryptionKey: vaultEncryptionKey,
            databaseManager: fixtures.databaseManager
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let vaultImporter = MockVaultArchiveImporter()
        let manager = RestoreManager(
            vaultKeyStore: vaultKeyStore,
            vaultArchiveImporter: vaultImporter,
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
        let archiveImporter = MockRestoreArchiveImporter()

        let bundleURL = try await createTestBundle(
            encryptionKey: vaultEncryptionKey,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let vaultImporter = MockVaultArchiveImporter()
        let manager = RestoreManager(
            vaultKeyStore: vaultKeyStore,
            vaultArchiveImporter: vaultImporter,
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

    @Test("Restore completed count excludes unused conversation inboxes")
    func testRestoreCompletedCountExcludesUnusedConversationInboxes() async throws {
        let fixtures = TestFixtures()
        let identityStore = MockKeychainIdentityStore()
        let (vaultKeyStore, vaultEncryptionKey) = try await seedVaultKey(store: identityStore)
        let archiveImporter = MockRestoreArchiveImporter()

        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)
        _ = try await inboxWriter.save(inboxId: "used-inbox", clientId: "used-client")
        _ = try await inboxWriter.save(inboxId: "unused-inbox", clientId: "unused-client")
        try await seedConversation(
            databaseWriter: fixtures.databaseManager.dbWriter,
            inboxId: "used-inbox",
            clientId: "used-client",
            isUnused: false
        )
        try await seedConversation(
            databaseWriter: fixtures.databaseManager.dbWriter,
            inboxId: "unused-inbox",
            clientId: "unused-client",
            isUnused: true
        )

        let bundleURL = try await createTestBundle(
            encryptionKey: vaultEncryptionKey,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let vaultImporter = MockVaultArchiveImporter()
        let manager = RestoreManager(
            vaultKeyStore: vaultKeyStore,
            vaultArchiveImporter: vaultImporter,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager,
            archiveImporter: archiveImporter,
            environment: .tests
        )

        try await manager.restoreFromBackup(bundleURL: bundleURL)

        let finalState = await manager.state
        guard case .completed(let inboxCount, _) = finalState else {
            Issue.record("Expected completed state, got \(finalState)")
            try? await fixtures.cleanup()
            return
        }
        #expect(inboxCount == 1)

        try? await fixtures.cleanup()
    }

    @Test("Restore prepares and finishes app lifecycle around database replacement")
    func testRestoreLifecycleControllerIsCalled() async throws {
        let fixtures = TestFixtures()
        let identityStore = MockKeychainIdentityStore()
        let (vaultKeyStore, vaultEncryptionKey) = try await seedVaultKey(store: identityStore)
        let archiveImporter = MockRestoreArchiveImporter()
        let lifecycleController = MockRestoreLifecycleController()

        let bundleURL = try await createTestBundle(
            encryptionKey: vaultEncryptionKey,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let vaultImporter = MockVaultArchiveImporter()
        let manager = RestoreManager(
            vaultKeyStore: vaultKeyStore,
            vaultArchiveImporter: vaultImporter,
            identityStore: identityStore,
            databaseManager: fixtures.databaseManager,
            archiveImporter: archiveImporter,
            restoreLifecycleController: lifecycleController,
            environment: .tests
        )

        try await manager.restoreFromBackup(bundleURL: bundleURL)

        #expect(await lifecycleController.prepareCallCount == 1)
        #expect(await lifecycleController.finishCallCount == 1)

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

@Suite("DatabaseManager Restore Tests", .serialized)
struct DatabaseManagerRestoreTests {
    @Test("replaceDatabase keeps captured readers valid after restore")
    func replaceDatabaseKeepsCapturedReadersValid() async throws {
        let environment: AppEnvironment = .tests
        let dbURL = environment.defaultDatabasesDirectoryURL.appendingPathComponent("convos.sqlite")
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")
        let backupPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("database-restore-\(UUID().uuidString).sqlite")

        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: walURL)
        try? FileManager.default.removeItem(at: shmURL)
        try? FileManager.default.removeItem(at: backupPath)

        let manager = DatabaseManager(environment: environment)
        defer {
            try? manager.dbPool.close()
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: walURL)
            try? FileManager.default.removeItem(at: shmURL)
            try? FileManager.default.removeItem(at: backupPath)
        }

        let inboxWriter = InboxWriter(dbWriter: manager.dbWriter)
        _ = try await inboxWriter.save(inboxId: "backup-inbox", clientId: "backup-client")

        let backupQueue = try DatabaseQueue(path: backupPath.path)
        defer { try? backupQueue.close() }
        try manager.dbReader.backup(to: backupQueue)

        _ = try await inboxWriter.save(inboxId: "post-backup-inbox", clientId: "post-backup-client")

        let capturedReader = manager.dbReader
        let preRestoreCount = try await capturedReader.read { db in
            try DBInbox.fetchCount(db)
        }
        #expect(preRestoreCount == 2)

        try manager.replaceDatabase(with: backupPath)

        let restoredCount = try await capturedReader.read { db in
            try DBInbox.fetchCount(db)
        }
        #expect(restoredCount == 1)

        let restoredInbox = try await capturedReader.read { db in
            try DBInbox.fetchOne(db, id: "backup-inbox")
        }
        #expect(restoredInbox != nil)
    }
}
