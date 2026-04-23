@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("BackupManager Tests", .serialized)
struct BackupManagerTests {
    // MARK: - Fixtures

    final class StubArchiveProvider: BackupArchiveProviding, @unchecked Sendable {
        private let lock: NSLock = NSLock()
        private var _stats: XMTPArchiveStats
        private var _payload: Data
        private var _throwing: (any Error)?
        var callCount: Int = 0
        var lastKey: Data?
        var lastPath: URL?

        init(
            stats: XMTPArchiveStats = .init(startNs: 1, endNs: 2),
            payload: Data = Data("archive-bytes".utf8),
            throwing: (any Error)? = nil
        ) {
            self._stats = stats
            self._payload = payload
            self._throwing = throwing
        }

        func createArchive(at path: URL, encryptionKey: Data) async throws -> XMTPArchiveStats {
            let outcome: (Data, XMTPArchiveStats?, (any Error)?) = lock.withLock {
                callCount += 1
                lastKey = encryptionKey
                lastPath = path
                return (_payload, _throwing == nil ? _stats : nil, _throwing)
            }
            if let error = outcome.2 {
                throw error
            }
            try outcome.0.write(to: path)
            return outcome.1 ?? _stats
        }
    }

    private struct Fixtures {
        let identityStore: MockKeychainIdentityStore
        let databaseManager: MockDatabaseManager
        let deviceInfo: MockDeviceInfoProvider
        let environment: AppEnvironment
    }

    private func freshFixtures() async throws -> Fixtures {
        let uniqueId = "device-\(UUID().uuidString)"
        return Fixtures(
            identityStore: MockKeychainIdentityStore(),
            databaseManager: MockDatabaseManager.makeTestDatabase(),
            deviceInfo: MockDeviceInfoProvider(
                deviceIdentifier: uniqueId,
                deviceName: "Test Device \(uniqueId)"
            ),
            environment: .tests
        )
    }

    private func seedIdentity(
        _ store: MockKeychainIdentityStore
    ) async throws -> KeychainIdentity {
        let keys = try await store.generateKeys()
        let identity = try await store.save(inboxId: "inbox-\(UUID().uuidString)", clientId: "client-1", keys: keys)
        return identity
    }

    // MARK: - Happy path

    @Test("createBackup writes a sealed bundle, sidecar, and invokes the archive provider once")
    func testCreateBackupHappyPath() async throws {
        let fixtures = try await freshFixtures()
        _ = try await seedIdentity(fixtures.identityStore)

        let provider = StubArchiveProvider()
        let manager = BackupManager(
            identityStore: fixtures.identityStore,
            archiveProvider: provider,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceInfo: fixtures.deviceInfo,
            environment: fixtures.environment
        )

        let bundleURL = try await manager.createBackup()
        #expect(FileManager.default.fileExists(atPath: bundleURL.path))
        #expect(provider.callCount == 1)
        #expect(provider.lastKey?.count == 32)

        // Sidecar sits next to the bundle, unencrypted.
        let sidecar = try BackupSidecarMetadata.read(from: bundleURL.deletingLastPathComponent())
        #expect(sidecar.schemaGeneration == LegacyDataWipe.currentGeneration)
        #expect(sidecar.conversationCount == 0)

        // Clean up the bundle dir to keep the shared temp env tidy across tests.
        try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent())
    }

    @Test("bundle decrypts under the identity's databaseKey and contains the XMTP archive bytes")
    func testBundleContentsRoundTrip() async throws {
        let fixtures = try await freshFixtures()
        let identity = try await seedIdentity(fixtures.identityStore)

        let expectedArchiveBytes = Data("xmtp-bytes-\(UUID().uuidString)".utf8)
        let provider = StubArchiveProvider(payload: expectedArchiveBytes)
        let manager = BackupManager(
            identityStore: fixtures.identityStore,
            archiveProvider: provider,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceInfo: fixtures.deviceInfo,
            environment: fixtures.environment
        )

        let bundleURL = try await manager.createBackup()
        let bundleData = try Data(contentsOf: bundleURL)

        let restoreDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: restoreDir) }

        try BackupBundle.unpack(data: bundleData, encryptionKey: identity.keys.databaseKey, to: restoreDir)

        let archiveOut = try Data(contentsOf: BackupBundle.archivePath(in: restoreDir))
        #expect(archiveOut == expectedArchiveBytes)

        let innerMeta = try BackupBundleMetadata.read(from: restoreDir)
        #expect(innerMeta.archiveKey.count == 32)
        #expect(innerMeta.archiveKey == provider.lastKey)
        #expect(innerMeta.archiveMetadata?.startNs == 1)
        #expect(innerMeta.archiveMetadata?.endNs == 2)

        try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent())
    }

    // MARK: - Skip conditions

    @Test("createBackup throws restoreInProgress when the flag is set")
    func testSkipsWhenRestoreInProgress() async throws {
        let fixtures = try await freshFixtures()
        _ = try await seedIdentity(fixtures.identityStore)

        let defaults = UserDefaults(suiteName: fixtures.environment.appGroupIdentifier) ?? .standard
        RestoreInProgressFlag.set(true, defaults: defaults)
        defer { RestoreInProgressFlag.set(false, defaults: defaults) }

        let provider = StubArchiveProvider()
        let manager = BackupManager(
            identityStore: fixtures.identityStore,
            archiveProvider: provider,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceInfo: fixtures.deviceInfo,
            environment: fixtures.environment
        )

        await #expect(throws: BackupError.self) {
            _ = try await manager.createBackup()
        }
        #expect(provider.callCount == 0)
    }

    @Test("createBackup throws noIdentityAvailable when the store is empty")
    func testSkipsWhenNoIdentity() async throws {
        let fixtures = try await freshFixtures()
        // Do NOT seed an identity.

        let provider = StubArchiveProvider()
        let manager = BackupManager(
            identityStore: fixtures.identityStore,
            archiveProvider: provider,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceInfo: fixtures.deviceInfo,
            environment: fixtures.environment
        )

        await #expect(throws: BackupError.self) {
            _ = try await manager.createBackup()
        }
        #expect(provider.callCount == 0)
    }

    // MARK: - Archive provider failures

    @Test("archive provider failure surfaces without leaving a half-written bundle")
    func testArchiveProviderFailurePropagates() async throws {
        let fixtures = try await freshFixtures()
        _ = try await seedIdentity(fixtures.identityStore)

        struct BoomError: Error {}
        let provider = StubArchiveProvider(throwing: BoomError())
        let manager = BackupManager(
            identityStore: fixtures.identityStore,
            archiveProvider: provider,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceInfo: fixtures.deviceInfo,
            environment: fixtures.environment
        )

        await #expect(throws: BoomError.self) {
            _ = try await manager.createBackup()
        }
        #expect(provider.callCount == 1)
    }
}
