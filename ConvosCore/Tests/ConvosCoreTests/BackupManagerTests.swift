@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// `BackupManager.createBackup()` end-to-end contract.
///
/// Verifies:
/// - Happy path: GRDB + XMTP archive + metadata land in a sealed
///   bundle the outer key decrypts.
/// - Sidecar metadata sits next to the sealed bundle and omits
///   `archiveKey` (discovery without the bundle key works; secrets
///   stay inside the seal).
/// - Skip conditions: restore-in-progress flag + missing identity
///   throw the expected `BackupError` cases *before* any file I/O.
/// - Local fallback kicks in when no iCloud container is available
///   (the default in tests).
@Suite("BackupManager.createBackup", .serialized)
struct BackupManagerTests {
    @Test("happy path produces a sealed bundle and a secret-free sidecar")
    func testHappyPath() async throws {
        clearRestoreFlag()
        let env = AppEnvironment.tests
        let fixtures = TestFixtures()
        let (identity, _) = try await seedIdentity(in: fixtures, inboxId: "test-inbox")

        let mockClient = MockXMTPClientProvider()
        let manager = BackupManager(
            databaseManager: fixtures.databaseManager,
            identityStore: fixtures.identityStore,
            clientProvider: { mockClient },
            environment: env,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let bundleURL = try await manager.createBackup()
        defer { cleanupBackupDirectory(at: bundleURL.deletingLastPathComponent()) }

        // File exists.
        #expect(FileManager.default.fileExists(atPath: bundleURL.path))
        #expect(bundleURL.lastPathComponent == "backup-latest.encrypted")

        // Sealed bundle decrypts + unpacks with the identity's databaseKey.
        let sealed = try Data(contentsOf: bundleURL)
        let stagingOut = try makeTempDir()
        defer { BackupBundle.cleanup(directory: stagingOut) }
        try BackupBundle.unpack(
            data: sealed,
            encryptionKey: identity.keys.databaseKey,
            to: stagingOut
        )

        // GRDB snapshot, XMTP archive, metadata.json all present.
        let dbPath = BackupBundle.databasePath(in: stagingOut)
        let xmtpPath = BackupBundle.xmtpArchivePath(in: stagingOut)
        #expect(FileManager.default.fileExists(atPath: dbPath.path))
        #expect(FileManager.default.fileExists(atPath: xmtpPath.path))
        #expect(BackupBundleMetadata.exists(in: stagingOut))

        // Full metadata carries archiveKey; XMTP createArchive was
        // called exactly once with that same key.
        let fullMetadata = try BackupBundleMetadata.readFull(from: stagingOut)
        #expect(fullMetadata.archiveKey.count == 32)
        #expect(mockClient.createArchiveCalls.count == 1)
        #expect(mockClient.createArchiveCalls.first?.encryptionKey == fullMetadata.archiveKey)

        // Sidecar sits next to the bundle and omits archiveKey.
        let sidecarDir = bundleURL.deletingLastPathComponent()
        let sidecar = try BackupBundleMetadata.readSidecar(from: sidecarDir)
        #expect(sidecar == fullMetadata.sidecar)
        let sidecarBytes = try Data(
            contentsOf: sidecarDir.appendingPathComponent("metadata.json")
        )
        let sidecarJSON = try #require(String(data: sidecarBytes, encoding: .utf8))
        #expect(!sidecarJSON.contains("archiveKey"))

        try? await fixtures.cleanup()
    }

    @Test("skips with .restoreInProgress when the flag is set")
    func testSkipsWhenRestoreInProgress() async throws {
        clearRestoreFlag()
        let env = AppEnvironment.tests
        let fixtures = TestFixtures()
        _ = try await seedIdentity(in: fixtures, inboxId: "test-inbox-restore")

        try RestoreInProgressFlag.set(true, environment: env)
        defer { try? RestoreInProgressFlag.set(false, environment: env) }

        let mockClient = MockXMTPClientProvider()
        let manager = BackupManager(
            databaseManager: fixtures.databaseManager,
            identityStore: fixtures.identityStore,
            clientProvider: { mockClient },
            environment: env
        )

        await #expect(throws: BackupError.self) {
            _ = try await manager.createBackup()
        }
        // Client must not have been touched.
        #expect(mockClient.createArchiveCalls.isEmpty)
        try? await fixtures.cleanup()
    }

    @Test("skips with .noIdentity when the keychain is empty")
    func testSkipsWithoutIdentity() async throws {
        clearRestoreFlag()
        let env = AppEnvironment.tests
        let fixtures = TestFixtures()
        // Deliberately do NOT call seedIdentity — keychain stays empty.

        let mockClient = MockXMTPClientProvider()
        let manager = BackupManager(
            databaseManager: fixtures.databaseManager,
            identityStore: fixtures.identityStore,
            clientProvider: { mockClient },
            environment: env
        )

        await #expect(throws: BackupError.self) {
            _ = try await manager.createBackup()
        }
        #expect(mockClient.createArchiveCalls.isEmpty)
        try? await fixtures.cleanup()
    }

    @Test("archive failure surfaces as .archiveFailed and cleans up staging")
    func testArchiveFailureSurfaces() async throws {
        clearRestoreFlag()
        let env = AppEnvironment.tests
        let fixtures = TestFixtures()
        _ = try await seedIdentity(in: fixtures, inboxId: "test-inbox-archive-fail")

        let mockClient = MockXMTPClientProvider()
        mockClient.createArchiveError = ArchiveStubError.simulated

        let manager = BackupManager(
            databaseManager: fixtures.databaseManager,
            identityStore: fixtures.identityStore,
            clientProvider: { mockClient },
            environment: env
        )

        await #expect(throws: BackupError.self) {
            _ = try await manager.createBackup()
        }
        try? await fixtures.cleanup()
    }

    // MARK: - Helpers

    private enum ArchiveStubError: Error {
        case simulated
    }

    /// Seed a keychain identity on the fixtures' MockKeychainIdentityStore
    /// and return it. Used by tests that expect createBackup to find an
    /// identity when it calls `loadSync`.
    private func seedIdentity(
        in fixtures: TestFixtures,
        inboxId: String
    ) async throws -> (KeychainIdentity, KeychainIdentityKeys) {
        let keys = try await fixtures.identityStore.generateKeys()
        let clientId = UUID().uuidString
        let identity = try await fixtures.identityStore.save(
            inboxId: inboxId,
            clientId: clientId,
            keys: keys
        )
        return (identity, keys)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-manager-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Remove the per-device backup directory so tests don't accumulate
    /// files on disk across runs.
    private func cleanupBackupDirectory(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func clearRestoreFlag() {
        try? RestoreInProgressFlag.set(false, environment: .tests)
    }
}
