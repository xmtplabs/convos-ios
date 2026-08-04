@testable import ConvosCore
import ConvosLogging
import Foundation
import GRDB
import os
import Security
import Testing

/// Verifies the production wiring of wipe-manifest handlers: the values the
/// handlers pass into their subsystems (keychain access group, log
/// directories, keychain slot names, image-cache method, app hooks), not
/// just the subsystems' own behavior — plus that the production executor
/// maps every manifest entry to a handler. These exist to catch
/// wrong-constant wiring bugs (sweeping the wrong log directory, querying
/// the wrong keychain access group, deleting the wrong slot) that
/// per-subsystem tests cannot see.
@Suite("Account Deletion Production Wiring")
struct AccountDeletionProductionWiringTests {
    private func makeRecord() -> AccountDeletionRecord {
        AccountDeletionRecord(
            operationId: UUID(),
            inboxId: "inbox-1",
            clientId: "client-1",
            ethAddress: "0xAbC123",
            deviceId: "device-1"
        )
    }

    private func makeSessionManager() -> SessionManager {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        return SessionManager(
            databaseWriter: databaseManager.dbWriter,
            databaseReader: databaseManager.dbReader,
            environment: .tests,
            identityStore: MockKeychainIdentityStore(),
            platformProviders: .mock,
            mode: .clipBootstrap
        )
    }

    // MARK: - Executor completeness

    @Test("The production executor maps every manifest entry to a handler once app hooks are registered")
    func productionExecutorHandlesEveryManifestEntry() {
        let manager = makeSessionManager()
        manager.setAccountDeletionAppHooks(AccountDeletionAppHooks(
            wipeStoreKitState: {},
            resetAnalyticsIdentity: {},
            wipeUserInterfaceDefaults: {}
        ))

        let executor = manager.makeAccountDeletionWipeExecutor()
        let manifest = Set(WipeManifest.entries(forVersion: WipeManifest.currentVersion))
        #expect(executor.handledEntries.isSuperset(of: manifest))
    }

    @Test("Without registered app hooks, exactly the app-owned entries are unhandled (loud failures, not skips)")
    func missingAppHooksLeaveExactlyAppEntriesUnhandled() {
        let manager = makeSessionManager()
        let executor = manager.makeAccountDeletionWipeExecutor()
        let manifest = Set(WipeManifest.entries(forVersion: WipeManifest.currentVersion))
        let unhandled = manifest.subtracting(executor.handledEntries)
        #expect(unhandled == [.storeKitDefaults, .analyticsIdentity, .userInterfaceDefaults])
    }

    // MARK: - App hook entries

    @Test("The app-hook entries drive the registered hooks and propagate their failures")
    func appHookEntriesDriveRegisteredHooks() async throws {
        let manager = makeSessionManager()
        let invoked = OSAllocatedUnfairLock<[String]>(initialState: [])
        manager.setAccountDeletionAppHooks(AccountDeletionAppHooks(
            wipeStoreKitState: { invoked.withLock { $0.append("storeKit") } },
            resetAnalyticsIdentity: { invoked.withLock { $0.append("analytics") } },
            wipeUserInterfaceDefaults: {
                invoked.withLock { $0.append("uiDefaults") }
                throw SyncedBackupRemovalIncompleteError()
            }
        ))
        let executor = manager.makeAccountDeletionWipeExecutor()
        let record = makeRecord()

        try await executor.run(entry: .storeKitDefaults, record: record)
        try await executor.run(entry: .analyticsIdentity, record: record)
        await #expect(throws: SyncedBackupRemovalIncompleteError.self) {
            try await executor.run(entry: .userInterfaceDefaults, record: record)
        }
        #expect(invoked.withLock { $0 } == ["storeKit", "analytics", "uiDefaults"])
    }

    // MARK: - Device-registration defaults entry

    @Test("The device-registration entry clears the real per-device defaults markers")
    func deviceRegistrationEntryClearsRealDefaults() async throws {
        let manager = makeSessionManager()
        let executor = manager.makeAccountDeletionWipeExecutor()
        let deviceId = PlatformProviders.mock.deviceInfo.deviceIdentifier
        let registeredKey = "hasRegisteredDevice_\(deviceId)"
        let tokenKey = "lastRegisteredDevicePushToken_\(deviceId)"
        UserDefaults.standard.set(true, forKey: registeredKey)
        UserDefaults.standard.set("token", forKey: tokenKey)
        defer {
            UserDefaults.standard.removeObject(forKey: registeredKey)
            UserDefaults.standard.removeObject(forKey: tokenKey)
        }

        try await executor.run(entry: .deviceRegistrationDefaults, record: makeRecord())

        #expect(UserDefaults.standard.object(forKey: registeredKey) == nil)
        #expect(UserDefaults.standard.object(forKey: tokenKey) == nil)
    }

    // MARK: - JWT keychain slots

    @Test("The SIWE and legacy JWT slot steps delete exactly the record-scoped slot names the auth paths use")
    func jwtSlotStepsDeleteRecordScopedAccounts() throws {
        let record = makeRecord()
        let deleted = OSAllocatedUnfairLock<[String]>(initialState: [])
        let capture: (String) throws -> Void = { account in
            deleted.withLock { $0.append(account) }
        }

        try AccountDeletionWipeSteps.wipeSiweJwtSlot(record: record, deleteAccount: capture)
        try AccountDeletionWipeSteps.wipeSiweAccountIdSlot(record: record, deleteAccount: capture)
        try AccountDeletionWipeSteps.wipeLegacyJwtSlot(record: record, deleteAccount: capture)

        // Pinned literals: these are the exact slot names the auth paths
        // write (KeychainAccount), reconstructed from the record because
        // the identity key may already be gone. The record lowercases the
        // address at init, matching the auth paths' lowercasing.
        #expect(deleted.withLock { $0 } == [
            "jwt:device-1:siwe:0xabc123",
            "accountId:device-1:siwe:0xabc123",
            "device-1",
        ])
        #expect(deleted.withLock { $0 } == [
            KeychainAccount.siweJwt(deviceId: record.deviceId, address: record.ethAddress),
            KeychainAccount.siweAccountId(deviceId: record.deviceId, address: record.ethAddress),
            KeychainAccount.jwt(deviceId: record.deviceId),
        ])
    }

    @Test("A failed slot delete fails its step instead of being swallowed")
    func jwtSlotStepFailurePropagates() {
        struct SlotDeleteFailure: Error {}
        #expect(throws: SlotDeleteFailure.self) {
            try AccountDeletionWipeSteps.wipeSiweJwtSlot(record: makeRecord()) { _ in
                throw SlotDeleteFailure()
            }
        }
    }
    // MARK: - Legacy keychain access group

    @Test("Legacy-identity sweep uses the team-prefixed keychain access group, not the bare app group")
    func legacySweepAccessGroupIsKeychainAccessGroup() {
        let environment = AppEnvironment.tests
        let group = AccountDeletionWipeSteps.legacyIdentitySweepAccessGroup(environment: environment)
        #expect(group == environment.keychainAccessGroup)
        #expect(group != environment.appGroupIdentifier)
        #expect(group.hasSuffix(environment.appGroupIdentifier))
    }

    @Test("Legacy-identity sweep queries every historical service with the given access group")
    func legacySweepQueriesEveryServiceWithAccessGroup() throws {
        let captured = OSAllocatedUnfairLock<[(service: String, group: String)]>(initialState: [])
        try LegacyDataWipe.wipeLegacyIdentityKeychainServices(accessGroup: "TEAM123.group.test") { service, group in
            captured.withLock { $0.append((service, group)) }
            return errSecSuccess
        }
        let calls = captured.withLock { $0 }
        #expect(calls.map(\.service) == LegacyDataWipe.legacyIdentityKeychainServices)
        #expect(calls.allSatisfy { $0.group == "TEAM123.group.test" })
    }

    @Test("A failed legacy service delete fails the sweep with the surviving services")
    func legacySweepFailurePropagates() {
        #expect(throws: LegacyKeychainSweepIncompleteError.self) {
            try LegacyDataWipe.wipeLegacyIdentityKeychainServices(accessGroup: "TEAM123.group.test") { service, _ in
                service.hasSuffix(".v2") ? errSecInternalError : errSecSuccess
            }
        }
    }

    // MARK: - Log directory selection

    @Test("The application log directory resolves through the production logger's own path derivation")
    func applicationLogDirectoryMatchesLogger() {
        let container = URL(fileURLWithPath: "/container", isDirectory: true)
        #expect(
            AppEnvironment.applicationLogsDirectory(inContainer: container)
                == FileLogHandler.logsDirectory(in: container)
        )
    }

    @Test("The wipe sweeps both the XMTP and the application log directories")
    func logSweepCoversBothLogDirectories() {
        let environment = AppEnvironment.tests
        let directories = AccountDeletionWipeSteps.logDirectoriesToSweep(environment: environment)
        #expect(directories.contains(environment.defaultXMTPLogsDirectoryURL))
        #expect(directories.contains(environment.defaultApplicationLogsDirectoryURL))
        #expect(environment.defaultApplicationLogsDirectoryURL != environment.defaultXMTPLogsDirectoryURL)
    }

    // MARK: - Image cache handler

    @Test("The image wipe step drives the shared cache's awaited method and propagates its failure")
    func imageWipeStepDrivesAwaitedSharedCacheMethod() async throws {
        let original = ImageCacheContainer.shared
        defer { ImageCacheContainer.shared = original }

        let awaitedCalls = OSAllocatedUnfairLock(initialState: 0)
        let spy = MockImageCache()
        spy.onRemoveAllPersistentImagesAndWait = {
            awaitedCalls.withLock { $0 += 1 }
        }
        ImageCacheContainer.shared = spy

        try await AccountDeletionWipeSteps.wipeImageCaches()
        #expect(awaitedCalls.withLock { $0 } == 1)

        spy.onRemoveAllPersistentImagesAndWait = {
            throw ImageCacheWipeIncompleteError(failedFileCount: 3)
        }
        await #expect(throws: ImageCacheWipeIncompleteError.self) {
            try await AccountDeletionWipeSteps.wipeImageCaches()
        }
    }
}
