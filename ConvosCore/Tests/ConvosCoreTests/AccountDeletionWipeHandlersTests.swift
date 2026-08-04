@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Exercises the real wipe-step implementations (not no-op fakes): file
/// sweeps against real directories including failure propagation, the
/// keychain identity family with a simulated non-propagating synchronizable
/// delete, GRDB row wipe plus compaction, and the app-group defaults sweep
/// against a real suite.
@Suite("Account Deletion Wipe Handlers")
struct AccountDeletionWipeHandlersTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wipe-handler-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRecord(inboxId: String = "inbox-1") -> AccountDeletionRecord {
        AccountDeletionRecord(
            operationId: UUID(),
            inboxId: inboxId,
            clientId: "client-1",
            ethAddress: "0xabc",
            deviceId: "device-1"
        )
    }

    // MARK: - File sweeps

    @Test("XMTP sweep removes xmtp-prefixed files and leaves everything else")
    func xmtpSweepRemovesMatchingFiles() throws {
        let directory = try makeTempDirectory()
        let xmtpFile = directory.appendingPathComponent("xmtp-node-abc123.db3")
        let sidecar = directory.appendingPathComponent("xmtp-node-abc123.db3-wal")
        let unrelated = directory.appendingPathComponent("keepme.txt")
        try Data("x".utf8).write(to: xmtpFile)
        try Data("x".utf8).write(to: sidecar)
        try Data("x".utf8).write(to: unrelated)

        try XMTPDatabaseFileSweeper.sweep(directory: directory)

        #expect(!FileManager.default.fileExists(atPath: xmtpFile.path))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("XMTP sweep on a missing directory is a no-op")
    func xmtpSweepMissingDirectoryNoOp() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("wipe-handler-missing-\(UUID().uuidString)", isDirectory: true)
        try XMTPDatabaseFileSweeper.sweep(directory: missing)
    }

    @Test("A file that cannot be removed fails the sweep instead of being logged away")
    func sweepFailurePropagates() throws {
        let parent = try makeTempDirectory()
        let locked = parent.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let victim = locked.appendingPathComponent("xmtp-stuck.db3")
        try Data("x".utf8).write(to: victim)
        // Remove write permission from the containing directory so the
        // unlink fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        #expect(throws: FileSweepIncompleteError.self) {
            try XMTPDatabaseFileSweeper.sweep(directory: locked)
        }
        // The durable record would survive this failure and retry later.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try XMTPDatabaseFileSweeper.sweep(directory: locked)
        #expect(!FileManager.default.fileExists(atPath: victim.path))
    }

    @Test("Log sweep removes every entry in the directory")
    func logSweepRemovesEverything() throws {
        let directory = try makeTempDirectory()
        try Data("log".utf8).write(to: directory.appendingPathComponent("libxmtp.log"))
        try Data("log".utf8).write(to: directory.appendingPathComponent("libxmtp.log.1"))

        try XMTPDatabaseFileSweeper.sweepContents(of: directory)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining.isEmpty)
    }

    // MARK: - Keychain identity family

    @Test("Keychain family step deletes the identity and its synced backup")
    func keychainFamilyStepDeletes() async throws {
        let store = MockKeychainIdentityStore()
        let keys = try KeychainIdentityKeys.generate()
        _ = try await store.save(inboxId: "inbox-1", clientId: "client-1", keys: keys)

        try await AccountDeletionWipeSteps.wipeKeychainIdentityFamily(
            identityStore: store,
            record: makeRecord(inboxId: "inbox-1")
        )

        #expect(try store.loadSync() == nil)
        #expect(try await store.loadSyncedBackups().isEmpty)
        #expect(try await store.loadInstallationMarker() == nil)
        #expect(try await store.loadConsentBackup() == nil)
    }

    @Test("A synced backup that fails to delete fails the step, never a silent assume")
    func keychainFamilyStepFailsOnSurvivingBackup() async throws {
        let store = MockKeychainIdentityStore()
        let keys = try KeychainIdentityKeys.generate()
        _ = try await store.save(inboxId: "inbox-1", clientId: "client-1", keys: keys)
        store._setSyncedBackupDeletionDisabled(true)

        await #expect(throws: SyncedBackupRemovalIncompleteError.self) {
            try await AccountDeletionWipeSteps.wipeKeychainIdentityFamily(
                identityStore: store,
                record: makeRecord(inboxId: "inbox-1")
            )
        }

        // Retry once the propagation issue clears; the step completes.
        store._setSyncedBackupDeletionDisabled(false)
        try await AccountDeletionWipeSteps.wipeKeychainIdentityFamily(
            identityStore: store,
            record: makeRecord(inboxId: "inbox-1")
        )
        #expect(try await store.loadSyncedBackups().isEmpty)
    }

    // MARK: - Database rows

    @Test("Database step clears account-scoped rows and compacts without error")
    func databaseRowsStepClearsAndCompacts() async throws {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        try await databaseManager.dbWriter.write { db in
            var inbox = DBInbox(inboxId: "inbox-1", clientId: "client-1")
            try inbox.insert(db)
        }
        let before = try await databaseManager.dbReader.read { db in
            try DBInbox.fetchCount(db)
        }
        #expect(before == 1)

        try await AccountDeletionWipeSteps.wipeDatabaseRows(databaseWriter: databaseManager.dbWriter)

        let after = try await databaseManager.dbReader.read { db in
            try DBInbox.fetchCount(db)
        }
        #expect(after == 0)
    }

    // MARK: - Defaults sweep

    @Test("Defaults sweep clears pairing, agent-timezone, and push-cursor keys by prefix")
    func defaultsSweeperRemovesPrefixedKeys() throws {
        let suiteName = "wipe-handler-suite-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create test defaults suite")
            return
        }
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set("x", forKey: "convos.pairing.nonceLedger.v2.abc")
        suite.set("x", forKey: "convos.pairing.pendingJoinRequest.v1")
        suite.set("x", forKey: "convos.agentTimezone.lastPublished.v1.convo")
        suite.set("x", forKey: "unrelated.key")

        let cursorKey = "convos.pushNotifications.lastWelcomeProcessed.inbox-1"
        UserDefaults.standard.set(Date(), forKey: cursorKey)
        defer { UserDefaults.standard.removeObject(forKey: cursorKey) }

        AccountDeletionDefaultsSweeper.sweepAppGroupStores(appGroupIdentifier: suiteName)

        #expect(suite.object(forKey: "convos.pairing.nonceLedger.v2.abc") == nil)
        #expect(suite.object(forKey: "convos.pairing.pendingJoinRequest.v1") == nil)
        #expect(suite.object(forKey: "convos.agentTimezone.lastPublished.v1.convo") == nil)
        #expect(suite.object(forKey: "unrelated.key") != nil)
        #expect(UserDefaults.standard.object(forKey: cursorKey) == nil)
    }
}
