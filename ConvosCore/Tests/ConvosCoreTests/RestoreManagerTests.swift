@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("RestoreManager Tests")
struct RestoreManagerTests {
    // MARK: - Fixtures

    final class StubArchiveProvider: BackupArchiveProviding, @unchecked Sendable {
        let payload: Data
        init(payload: Data = Data("archive".utf8)) { self.payload = payload }
        func currentInstallationId() async throws -> String {
            "mock-installation-id"
        }
        func createArchive(at path: URL, encryptionKey: Data) async throws -> XMTPArchiveStats {
            try payload.write(to: path)
            return XMTPArchiveStats(startNs: nil, endNs: nil, installationId: "mock-installation-id")
        }
    }

    final class StubArchiveImporter: RestoreArchiveImporting, @unchecked Sendable {
        private let lock: NSLock = NSLock()
        var callCount: Int = 0
        var throwing: (any Error)?
        var archiveImportFailureReason: String?
        let installationId: String = "install-\(UUID().uuidString)"
        func importArchive(
            at path: URL,
            encryptionKey: Data,
            identity: KeychainIdentity
        ) async throws -> RestoreArchiveImportResult {
            let result = lock.withLock { () -> (throwing: (any Error)?, failureReason: String?) in
                callCount += 1
                return (throwing, archiveImportFailureReason)
            }
            if let err = result.throwing { throw err }
            return RestoreArchiveImportResult(
                installationId: installationId,
                archiveImportFailureReason: result.failureReason
            )
        }
    }

    final class StubLifecycle: RestoreLifecycleControlling, @unchecked Sendable {
        private let lock: NSLock = NSLock()
        var pauseCount: Int = 0
        var resumeCount: Int = 0
        func pauseForRestore() async { lock.withLock { pauseCount += 1 } }
        func resumeAfterRestore() async { lock.withLock { resumeCount += 1 } }
    }

    private struct Fixtures {
        let identityStore: MockKeychainIdentityStore
        let databaseManager: MockDatabaseManager
        let deviceInfo: MockDeviceInfoProvider
        let archiveProvider: StubArchiveProvider
        let archiveImporter: StubArchiveImporter
        let lifecycle: StubLifecycle
        let environment: AppEnvironment
        let suite: String

        var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }
    }

    private func makeFixtures() -> Fixtures {
        let environment: AppEnvironment = .tests
        // Unique suite per test isolates the flag, transaction record, and
        // pending-failure summary from parallel suites on the same
        // AppEnvironment.
        let suite = "convos.tests.RestoreManager.\(UUID().uuidString)"
        (UserDefaults(suiteName: suite) ?? .standard).removePersistentDomain(forName: suite)
        let uniqueId = "device-\(UUID().uuidString)"
        return Fixtures(
            identityStore: MockKeychainIdentityStore(),
            databaseManager: MockDatabaseManager.makeTestDatabase(),
            deviceInfo: MockDeviceInfoProvider(
                deviceIdentifier: uniqueId,
                deviceName: "Test Device \(uniqueId)"
            ),
            archiveProvider: StubArchiveProvider(),
            archiveImporter: StubArchiveImporter(),
            lifecycle: StubLifecycle(),
            environment: environment,
            suite: suite
        )
    }

    private func seedIdentity(_ store: MockKeychainIdentityStore) async throws -> KeychainIdentity {
        let keys = try await store.generateKeys()
        return try await store.save(
            inboxId: "inbox-\(UUID().uuidString)",
            clientId: "client-\(UUID().uuidString)",
            keys: keys
        )
    }

    /// BackupManager refuses to bundle when there are 0 conversations.
    /// Seed one before calling makeBackup.
    private func seedConversation(in f: Fixtures) async throws {
        try await f.databaseManager.dbWriter.write { db in
            let id = UUID().uuidString
            let creatorInboxId = "inbox-\(id)"
            try DBMember(inboxId: creatorInboxId).save(db, onConflict: .ignore)
            try DBConversation(
                id: id,
                clientConversationId: id,
                inviteTag: "tag-\(id)",
                creatorId: creatorInboxId,
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
                conversationEmoji: nil,
                imageLastRenewed: nil,
                isUnused: false,
                hasHadVerifiedAssistant: false
            ).insert(db)
        }
    }

    private func makeBackup(_ f: Fixtures) async throws -> URL {
        try await seedConversation(in: f)
        let manager = BackupManager(
            identityStore: f.identityStore,
            archiveProvider: f.archiveProvider,
            databaseReader: f.databaseManager.dbReader,
            deviceInfo: f.deviceInfo,
            environment: f.environment,
            restoreFlagSuiteName: f.suite
        )
        let url = try await manager.createBackup()
        return url
    }

    // MARK: - restoreFromBackup happy path

    @Test("restoreFromBackup succeeds: lifecycle pause/resume fire, revoker keeps throwaway install")
    func testHappyPath() async throws {
        let f = makeFixtures()
        _ = try await seedIdentity(f.identityStore)
        let bundleURL = try await makeBackup(f)
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        // Spy revoker so we can assert the keepInstallationId passed in
        // is the throwaway importer's id (not the pre-restore identity's
        // clientId, which was the previous bug).
        let recorder = RevokerRecorder()
        let revoker: RestoreInstallationRevoker = { inboxId, _, keepId in
            recorder.record(inboxId: inboxId, keep: keepId)
            return 1
        }

        let manager = RestoreManager(
            identityStore: f.identityStore,
            databaseManager: f.databaseManager,
            archiveImporter: f.archiveImporter,
            lifecycleController: f.lifecycle,
            installationRevoker: revoker,
            environment: f.environment,
            restoreFlagSuiteName: f.suite
        )
        try await manager.restoreFromBackup(bundleURL: bundleURL)
        let state = await manager.state
        #expect(state == .completed)
        #expect(f.lifecycle.pauseCount == 1)
        #expect(f.lifecycle.resumeCount == 1)
        #expect(f.archiveImporter.callCount == 1)
        #expect(recorder.calls == 1)
        #expect(recorder.lastKeep == f.archiveImporter.installationId)
        #expect(RestoreInProgressFlag.isSet(defaults: f.defaults) == false)
        #expect(RestoreTransactionStore.load(defaults: f.defaults) == nil)
    }

    @Test("revocation still runs when archive import fails after installation creation")
    func testRevocationRunsOnPartialArchiveFailure() async throws {
        let f = makeFixtures()
        _ = try await seedIdentity(f.identityStore)
        let bundleURL = try await makeBackup(f)
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        f.archiveImporter.archiveImportFailureReason = "corrupt archive"
        let recorder = RevokerRecorder()
        let revoker: RestoreInstallationRevoker = { _, _, keep in
            recorder.record(inboxId: "", keep: keep)
            return 0
        }
        let manager = RestoreManager(
            identityStore: f.identityStore,
            databaseManager: f.databaseManager,
            archiveImporter: f.archiveImporter,
            lifecycleController: f.lifecycle,
            installationRevoker: revoker,
            environment: f.environment,
            restoreFlagSuiteName: f.suite
        )
        try await manager.restoreFromBackup(bundleURL: bundleURL)

        #expect(recorder.calls == 1)
        #expect(recorder.lastKeep == f.archiveImporter.installationId)
        if case .archiveImportFailed = await manager.state {
            // expected
        } else {
            Issue.record("expected archiveImportFailed")
        }
    }

    @Test("revocation is skipped if installation creation fails before a keeper exists")
    func testRevocationSkippedWhenInstallationCreationFails() async throws {
        let f = makeFixtures()
        _ = try await seedIdentity(f.identityStore)
        let bundleURL = try await makeBackup(f)
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        struct BoomError: Error {}
        f.archiveImporter.throwing = BoomError()
        let recorder = RevokerRecorder()
        let revoker: RestoreInstallationRevoker = { _, _, keep in
            recorder.record(inboxId: "", keep: keep)
            return 0
        }
        let manager = RestoreManager(
            identityStore: f.identityStore,
            databaseManager: f.databaseManager,
            archiveImporter: f.archiveImporter,
            lifecycleController: f.lifecycle,
            installationRevoker: revoker,
            environment: f.environment,
            restoreFlagSuiteName: f.suite
        )
        try await manager.restoreFromBackup(bundleURL: bundleURL)

        #expect(recorder.calls == 0)
    }

    final class RevokerRecorder: @unchecked Sendable {
        private let lock: NSLock = NSLock()
        private(set) var calls: Int = 0
        private(set) var lastKeep: String?
        func record(inboxId: String, keep: String?) {
            lock.withLock {
                calls += 1
                lastKeep = keep
            }
        }
    }

    // MARK: - Archive import failure is non-fatal

    @Test("archiveImportFailed is terminal-partial, flag/record clear, summary persists")
    func testArchiveImportFailureNonFatal() async throws {
        let f = makeFixtures()
        _ = try await seedIdentity(f.identityStore)
        let bundleURL = try await makeBackup(f)
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        f.archiveImporter.archiveImportFailureReason = "corrupt archive"
        let manager = RestoreManager(
            identityStore: f.identityStore,
            databaseManager: f.databaseManager,
            archiveImporter: f.archiveImporter,
            lifecycleController: f.lifecycle,
            environment: f.environment,
            restoreFlagSuiteName: f.suite
        )
        try await manager.restoreFromBackup(bundleURL: bundleURL)

        let state = await manager.state
        if case .archiveImportFailed = state {
            // expected
        } else {
            Issue.record("expected archiveImportFailed, got \(state)")
        }
        #expect(f.lifecycle.resumeCount == 1)
        #expect(RestoreInProgressFlag.isSet(defaults: f.defaults) == false)
        #expect(PendingArchiveImportFailureStorage.load(defaults: f.defaults) != nil)
        PendingArchiveImportFailureStorage.clear(defaults: f.defaults)
    }

    // MARK: - schemaGeneration mismatch refuses the bundle

    @Test("schemaGeneration mismatch throws distinct error before destructive ops")
    func testSchemaGenerationMismatch() async throws {
        let f = makeFixtures()
        let identity = try await seedIdentity(f.identityStore)

        // Build a bundle with the wrong schemaGeneration by hand.
        let stagingDir = try BackupBundle.createStagingDirectory()
        defer { BackupBundle.cleanup(directory: stagingDir) }
        try Data("sqlite".utf8).write(to: BackupBundle.databasePath(in: stagingDir))
        try Data("archive".utf8).write(to: BackupBundle.archivePath(in: stagingDir))
        let badInner = BackupBundleMetadata(
            deviceId: "d",
            deviceName: "n",
            osString: "ios",
            conversationCount: 0,
            schemaGeneration: "ancient-v0",
            appVersion: "1.0.0",
            archiveKey: Data(repeating: 0xAA, count: 32)
        )
        try BackupBundleMetadata.write(badInner, to: stagingDir)
        let sealed = try BackupBundle.pack(directory: stagingDir, encryptionKey: identity.keys.databaseKey)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-bundle-\(UUID().uuidString).encrypted")
        try sealed.write(to: bundleURL)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let manager = RestoreManager(
            identityStore: f.identityStore,
            databaseManager: f.databaseManager,
            archiveImporter: f.archiveImporter,
            environment: f.environment,
            restoreFlagSuiteName: f.suite
        )
        do {
            try await manager.restoreFromBackup(bundleURL: bundleURL)
            Issue.record("expected schemaGenerationMismatch")
        } catch let error as RestoreError {
            if case .schemaGenerationMismatch = error {
                // expected — and no destructive op should have run
                #expect(f.archiveImporter.callCount == 0)
                #expect(RestoreInProgressFlag.isSet(defaults: f.defaults) == false)
            } else {
                Issue.record("expected schemaGenerationMismatch, got \(error)")
            }
        }
    }

    // MARK: - findAvailableBackup

    @Test("findAvailableBackup returns newest compatible sidecar")
    func testFindAvailableBackup() async throws {
        let f = makeFixtures()
        _ = try await seedIdentity(f.identityStore)
        let bundleURL = try await makeBackup(f)
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        let manager = RestoreManager(
            identityStore: f.identityStore,
            databaseManager: f.databaseManager,
            archiveImporter: f.archiveImporter,
            environment: f.environment,
            restoreFlagSuiteName: f.suite
        )
        let available = await manager.findAvailableBackup()
        #expect(available != nil)
        #expect(available?.sidecar.schemaGeneration == LegacyDataWipe.currentGeneration)
        #expect(available?.bundleURL.lastPathComponent == "backup-latest.encrypted")
    }

    @Test("findAvailableBackup rejects sidecars with stale schemaGeneration")
    func testFindAvailableBackupRejectsStale() async throws {
        let f = makeFixtures()

        // Manually write a sidecar with wrong schemaGeneration into a backups/<deviceId>/ dir.
        let backupsDir = f.environment.defaultDatabasesDirectoryURL
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("stale-device-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: backupsDir.deletingLastPathComponent()) }

        let staleSidecar = BackupSidecarMetadata(
            deviceId: "stale",
            deviceName: "Stale Device",
            osString: "ios",
            conversationCount: 0,
            schemaGeneration: "ancient-v0",
            appVersion: "0.0.1"
        )
        try BackupSidecarMetadata.write(staleSidecar, to: backupsDir)

        let manager = RestoreManager(
            identityStore: f.identityStore,
            databaseManager: f.databaseManager,
            archiveImporter: f.archiveImporter,
            environment: f.environment,
            restoreFlagSuiteName: f.suite
        )
        let found = await manager.findAvailableBackup()
        #expect(found == nil)
    }

    // The restoreAlreadyInProgress guard would require setting the
    // process-wide RestoreInProgressFlag — which collides with parallel
    // BackupManagerTests that read the same app-group UserDefaults. The
    // guard is exercised at the flag level by RestoreInProgressFlagTests;
    // the branch in restoreFromBackup is visible and trivial.
}
