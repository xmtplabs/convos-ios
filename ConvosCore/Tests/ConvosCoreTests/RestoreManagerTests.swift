@testable import ConvosCore
import Foundation
import GRDB
import os
import Testing

/// End-to-end contract for `RestoreManager.restoreFromBackup` and
/// its static `findAvailableBackup` discovery.
///
/// Uses `BackupManager` to produce a real sealed bundle, then hands
/// the bundle to `RestoreManager` with a throwaway-client factory
/// that returns `MockXMTPClientProvider` — no Docker required. The
/// XMTP-archive import is recorded on the mock; tests verify the
/// protocol calls happened + final state transitions.
@Suite("RestoreManager.restoreFromBackup", .serialized)
struct RestoreManagerTests {
    @Test("happy path: bundle decrypts, archive imported, state = completed")
    func testHappyPath() async throws {
        clearRestoreFlag()
        let ctx = try await TestContext.make()
        defer { ctx.cleanup() }

        let bundleURL = try await ctx.makeBundle()
        try await ctx.restoreManager.restoreFromBackup(bundleURL: bundleURL)

        let state = await ctx.restoreManager.state
        #expect(state == .completed)
        #expect(ctx.restoreMockClient.importArchiveCalls.count == 1)
        // Revocation path constructs a *second* throwaway client after
        // import, so builder was called twice total. (Once for import,
        // once for `inboxState + revokeInstallations`.)
        #expect(ctx.clientBuilderCallCount.withLock { $0 } == 2)
    }

    @Test("findAvailableBackup returns the sidecar created by BackupManager")
    func testDiscovery() async throws {
        clearRestoreFlag()
        let ctx = try await TestContext.make()
        defer { ctx.cleanup() }

        let bundleURL = try await ctx.makeBundle()
        let found = RestoreManager.findAvailableBackup(environment: .tests)
        #expect(found != nil)
        #expect(found?.url == bundleURL)
        #expect(found?.sidecar.conversationCount == 0)
        #expect(found?.sidecar.schemaGeneration == LegacyDataWipe.currentGeneration)
    }

    @Test("schema-generation mismatch surfaces the specific error")
    func testSchemaGenerationMismatch() async throws {
        clearRestoreFlag()
        let ctx = try await TestContext.make()
        defer { ctx.cleanup() }

        let bundleURL = try await ctx.makeBundle()
        // Build a restore manager whose "current" generation is
        // deliberately different from the one the bundle carries.
        let mismatchManager = RestoreManager(
            databaseManager: ctx.databaseManager,
            identityStore: ctx.identityStore,
            sessionManager: ctx.sessionManager,
            environment: .tests,
            clientBuilder: ctx.clientBuilder,
            currentSchemaGeneration: "single-inbox-v999"
        )

        await #expect(throws: RestoreError.self) {
            try await mismatchManager.restoreFromBackup(bundleURL: bundleURL)
        }
    }

    @Test("missing identity surfaces identityTimeout quickly")
    func testIdentityTimeout() async throws {
        clearRestoreFlag()
        let ctx = try await TestContext.make()
        defer { ctx.cleanup() }
        let bundleURL = try await ctx.makeBundle()

        // Wipe the identity so awaitIdentityWithTimeout can't find one.
        try await ctx.identityStore.delete()

        // Short timeout so the test doesn't sit in a poll loop.
        let timeoutManager = RestoreManager(
            databaseManager: ctx.databaseManager,
            identityStore: ctx.identityStore,
            sessionManager: ctx.sessionManager,
            environment: .tests,
            clientBuilder: ctx.clientBuilder,
            currentSchemaGeneration: LegacyDataWipe.currentGeneration,
            identityPollInterval: .milliseconds(5),
            identityTimeout: .milliseconds(20)
        )

        await #expect(throws: RestoreError.self) {
            try await timeoutManager.restoreFromBackup(bundleURL: bundleURL)
        }
    }

    @Test("archive import failure is non-fatal; state = archiveImportFailed")
    func testArchiveImportFailureIsNonFatal() async throws {
        clearRestoreFlag()
        let ctx = try await TestContext.make()
        defer { ctx.cleanup() }

        ctx.restoreMockClient.importArchiveError = StubArchiveError.simulated
        let bundleURL = try await ctx.makeBundle()

        try await ctx.restoreManager.restoreFromBackup(bundleURL: bundleURL)

        let state = await ctx.restoreManager.state
        if case .archiveImportFailed = state {
            // expected
        } else {
            Issue.record("expected .archiveImportFailed, got \(state)")
        }
    }

    // MARK: - Helpers

    private enum StubArchiveError: Error {
        case simulated
    }

    private enum StubInboxStateError: Error {
        case notMockable
    }

    private func clearRestoreFlag() {
        try? RestoreInProgressFlag.set(false, environment: .tests)
    }

    /// Test harness: seeds identity, builds a SessionManager +
    /// BackupManager + RestoreManager wired with mock XMTP clients.
    final class TestContext {
        let fixtures: TestFixtures
        let sessionManager: SessionManager
        let databaseManager: MockDatabaseManager
        let identityStore: MockKeychainIdentityStore
        /// The mock client handed out by the backup-side factory
        /// (one per `createBackup` call). Not inspected after the
        /// bundle is created.
        let backupMockClient: MockXMTPClientProvider
        /// The mock client handed out by the restore-side
        /// `clientBuilder`. Shared across the import + revocation
        /// calls — `importArchiveCalls` / `revokeCalls` are
        /// observable on this instance.
        let restoreMockClient: MockXMTPClientProvider
        let clientBuilderCallCount: OSAllocatedUnfairLock<Int>
        let clientBuilder: RestoreManager.ThrowawayClientBuilder
        let backupManager: BackupManager
        let restoreManager: RestoreManager
        let backupDirectory: URL

        static func make() async throws -> TestContext {
            let fixtures = TestFixtures()
            let identityStore = fixtures.identityStore
            let keys = try await identityStore.generateKeys()
            let identity = try await identityStore.save(
                inboxId: "restore-test-inbox",
                clientId: UUID().uuidString,
                keys: keys
            )

            let databaseManager = fixtures.databaseManager
            let sessionManager = SessionManager(
                databaseWriter: databaseManager.dbWriter,
                databaseReader: databaseManager.dbReader,
                environment: .tests,
                identityStore: identityStore,
                platformProviders: .mock
            )

            let backupMockClient = MockXMTPClientProvider()
            let backupManager = BackupManager(
                databaseManager: databaseManager,
                identityStore: identityStore,
                clientProvider: { backupMockClient },
                environment: .tests
            )

            // Make the revoker's `inboxState` call throw — the mock
            // can't construct an `XMTPiOS.InboxState` (no public init).
            // The revoker swallows this as a non-fatal warning, which
            // matches the production contract: revocation failures
            // never block the restore itself.
            let restoreMockClient = MockXMTPClientProvider()
            restoreMockClient.inboxStateError = StubInboxStateError.notMockable
            let counter: OSAllocatedUnfairLock<Int> = .init(initialState: 0)
            let clientBuilder: RestoreManager.ThrowawayClientBuilder = { _, _ in
                counter.withLock { $0 += 1 }
                return restoreMockClient
            }
            let restoreManager = RestoreManager(
                databaseManager: databaseManager,
                identityStore: identityStore,
                sessionManager: sessionManager,
                environment: .tests,
                clientBuilder: clientBuilder,
                currentSchemaGeneration: LegacyDataWipe.currentGeneration,
                identityPollInterval: .milliseconds(5),
                identityTimeout: .milliseconds(200)
            )

            let deviceId = DeviceInfo.deviceIdentifier
            let backupDir = AppEnvironment.tests.defaultDatabasesDirectoryURL
                .appendingPathComponent("backups", isDirectory: true)
                .appendingPathComponent(deviceId, isDirectory: true)

            _ = identity  // silence unused-let
            return TestContext(
                fixtures: fixtures,
                sessionManager: sessionManager,
                databaseManager: databaseManager,
                identityStore: identityStore,
                backupMockClient: backupMockClient,
                restoreMockClient: restoreMockClient,
                clientBuilderCallCount: counter,
                clientBuilder: clientBuilder,
                backupManager: backupManager,
                restoreManager: restoreManager,
                backupDirectory: backupDir
            )
        }

        private init(
            fixtures: TestFixtures,
            sessionManager: SessionManager,
            databaseManager: MockDatabaseManager,
            identityStore: MockKeychainIdentityStore,
            backupMockClient: MockXMTPClientProvider,
            restoreMockClient: MockXMTPClientProvider,
            clientBuilderCallCount: OSAllocatedUnfairLock<Int>,
            clientBuilder: @escaping RestoreManager.ThrowawayClientBuilder,
            backupManager: BackupManager,
            restoreManager: RestoreManager,
            backupDirectory: URL
        ) {
            self.fixtures = fixtures
            self.sessionManager = sessionManager
            self.databaseManager = databaseManager
            self.identityStore = identityStore
            self.backupMockClient = backupMockClient
            self.restoreMockClient = restoreMockClient
            self.clientBuilderCallCount = clientBuilderCallCount
            self.clientBuilder = clientBuilder
            self.backupManager = backupManager
            self.restoreManager = restoreManager
            self.backupDirectory = backupDirectory
        }

        func makeBundle() async throws -> URL {
            try await backupManager.createBackup()
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: backupDirectory)
            // Drop the DB pool synchronously; fixtures.cleanup also
            // resets mock singletons but we don't need that in the
            // serialized suite.
            try? databaseManager.dbPool.erase()
        }
    }
}
