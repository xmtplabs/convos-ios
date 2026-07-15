@testable import ConvosCore
import ConvosLogging
import Foundation
import os
import Security
import Testing

/// Verifies the production wiring of wipe-manifest handlers: the values the
/// handlers pass into their subsystems (keychain access group, log
/// directories, image-cache method), not just the subsystems' own behavior.
/// These exist to catch wrong-constant wiring bugs (sweeping the wrong log
/// directory, querying the wrong keychain access group) that per-subsystem
/// tests cannot see.
@Suite("Account Deletion Production Wiring")
struct AccountDeletionProductionWiringTests {
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
