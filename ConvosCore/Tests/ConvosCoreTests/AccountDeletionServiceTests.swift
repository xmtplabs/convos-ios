@testable import ConvosCore
import Foundation
import os
import Testing

/// Covers the deletion flow's ordering invariant (backend before any
/// teardown), the single confirmation channel (endpoint 200 or the
/// barrier's terminal mint response), the launch-recovery matrix, and
/// wipe-resume semantics.
@Suite("Account Deletion Service")
struct AccountDeletionServiceTests {
    // MARK: - Harness

    private final class EventLog: @unchecked Sendable {
        private let lock: NSLock = NSLock()
        private var storage: [String] = []

        func record(_ event: String) {
            lock.lock(); defer { lock.unlock() }
            storage.append(event)
        }

        var events: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func contains(_ event: String) -> Bool {
            events.contains(event)
        }
    }

    private struct Config {
        var identity: KeychainIdentity?
        var mint: @Sendable (KeychainIdentity) async throws -> String = { _ in "jwt" }
        var deletion: (@Sendable (UUID, String) async throws -> ConvosAPI.AccountDeletionResponse)?
        var failingEntries: Set<WipeManifestEntry> = []
        var cachedToken: @Sendable (AccountDeletionRecord) -> String? = { _ in nil }
        var ethAddress: @Sendable (KeychainIdentity) -> String = { _ in "0xabc" }
    }

    private func makeStore() throws -> AccountDeletionStateStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-deletion-service-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return AccountDeletionStateStore(directoryURL: url)
    }

    private func makeIdentity() throws -> KeychainIdentity {
        KeychainIdentity(inboxId: "inbox-1", clientId: "client-1", keys: try KeychainIdentityKeys.generate())
    }

    private func makeService(
        store: AccountDeletionStateStore,
        events: EventLog,
        config: Config
    ) -> AccountDeletionService {
        let deletion = config.deletion ?? { operationId, _ in
            ConvosAPI.AccountDeletionResponse(
                status: "deleted",
                operationId: operationId.uuidString.lowercased(),
                deletedAt: Date(),
                purgeWindowHours: 24
            )
        }
        let failingEntries = config.failingEntries
        let identity = config.identity
        let mint = config.mint
        let cachedToken = config.cachedToken
        let ethAddress = config.ethAddress
        let dependencies = AccountDeletionDependencies(
            loadIdentity: { identity },
            deviceId: { "device-1" },
            ethAddress: ethAddress,
            mintToken: { identityValue in
                events.record("mint(phase: \(store.load().activeRecord?.phase.rawValue ?? "none"))")
                return try await mint(identityValue)
            },
            cachedToken: { record in
                cachedToken(record)
            },
            requestDeletion: { operationId, jwt in
                events.record("delete(\(operationId.uuidString.lowercased()), jwt: \(jwt), phase: \(store.load().activeRecord?.phase.rawValue ?? "none"))")
                return try await deletion(operationId, jwt)
            },
            setReauthSuspended: { suspended in
                events.record("reauthSuspended(\(suspended))")
            },
            revokeInstallations: { record in
                events.record("revoke(phase: \(record.phase.rawValue))")
            },
            stopServices: {
                events.record("stopServices")
            },
            makeWipeExecutor: {
                var handlers: [WipeManifestEntry: WipeStep] = [:]
                for entry in WipeManifestEntry.allCases {
                    handlers[entry] = WipeStep { _ in
                        events.record("wipe(\(entry.rawValue))")
                        if failingEntries.contains(entry) {
                            throw SyncedBackupRemovalIncompleteError()
                        }
                    }
                }
                return WipeManifestExecutor(handlers: handlers)
            },
            sweepRecordScopedSlots: { record in
                events.record("sweepRecordScopedSlots(\(record.inboxId))")
            }
        )
        return AccountDeletionService(store: store, dependencies: dependencies)
    }

    // MARK: - Happy path

    @Test("Happy path: record before request, backend before teardown, record cleared last")
    func happyPathOrdering() async throws {
        let store = try makeStore()
        let events = EventLog()
        let service = makeService(store: store, events: events, config: Config(identity: try makeIdentity()))

        let progressLog = EventLog()
        try await service.deleteAccount { progressLog.record("\($0)") }

        let all = events.events
        // The record exists (requested) before the mint and the request.
        #expect(all.contains("mint(phase: requested)"))
        #expect(all.first(where: { $0.hasPrefix("delete(") })?.contains("phase: requested") == true)
        // No teardown before the request: stopServices and wipe entries
        // come strictly after the delete call.
        let deleteIndex = try #require(all.firstIndex(where: { $0.hasPrefix("delete(") }))
        let stopIndex = try #require(all.firstIndex(of: "stopServices"))
        let firstWipeIndex = try #require(all.firstIndex(where: { $0.hasPrefix("wipe(") }))
        #expect(deleteIndex < stopIndex)
        #expect(deleteIndex < firstWipeIndex)
        // Revocation runs from backendConfirmed, before the wipe.
        let revokeIndex = try #require(all.firstIndex(of: "revoke(phase: backend_confirmed)"))
        #expect(deleteIndex < revokeIndex)
        #expect(revokeIndex < firstWipeIndex)
        // Completion clears the record and lifts the reauth suspension.
        #expect(store.load().activeRecord == nil)
        #expect(all.last == "reauthSuspended(false)")
        #expect(progressLog.events == [
            "requestingBackendDeletion", "revokingDevices", "wipingLocalData", "completed",
        ])
    }

    // MARK: - Failure ordering

    @Test("Backend request failure: nothing torn down, record stays requested, keys intact")
    func requestFailureTearsNothingDown() async throws {
        let store = try makeStore()
        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.deletion = { _, _ in throw APIError.serverError("boom") }
        let service = makeService(store: store, events: events, config: config)

        await #expect(throws: AccountDeletionError.self) {
            try await service.deleteAccount { _ in }
        }
        #expect(!events.contains("stopServices"))
        #expect(!events.events.contains(where: { $0.hasPrefix("wipe(") }))
        #expect(!events.events.contains(where: { $0.hasPrefix("revoke(") }))
        #expect(store.load().activeRecord?.phase == .requested)
        // Suspension stays on while the record is pending.
        #expect(events.events.last != "reauthSuspended(false)")
    }

    @Test("Mint failure on a fresh record clears it: provably nothing was sent")
    func preflightFailureClearsFreshRecord() async throws {
        let store = try makeStore()
        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.mint = { _ in throw SIWEAuthError.invalidNonceOrSignature(nil) }
        let service = makeService(store: store, events: events, config: config)

        await #expect(throws: AccountDeletionError.self) {
            try await service.deleteAccount { _ in }
        }
        #expect(store.load().activeRecord == nil)
        #expect(events.events.last == "reauthSuspended(false)")
        #expect(!events.events.contains(where: { $0.hasPrefix("wipe(") }))
    }

    @Test("Mint failure during recovery keeps the pre-existing record")
    func preflightFailureKeepsExistingRecord() async throws {
        let store = try makeStore()
        let identity = try makeIdentity()
        let record = AccountDeletionRecord(
            operationId: UUID(), inboxId: identity.inboxId, clientId: identity.clientId,
            ethAddress: "0xabc", deviceId: "device-1"
        )
        try await store.begin(record)

        let events = EventLog()
        var config = Config(identity: identity)
        config.mint = { _ in throw SIWEAuthError.invalidNonceOrSignature(nil) }
        let service = makeService(store: store, events: events, config: config)

        await service.recoverAtLaunch()
        #expect(store.load().activeRecord?.phase == .requested)
        #expect(!events.events.contains(where: { $0.hasPrefix("wipe(") }))
    }

    // MARK: - Confirmation semantics

    @Test("Terminal identity-deleted at mint promotes a pending record and completes the wipe")
    func identityDeletedPromotesPendingRecord() async throws {
        let store = try makeStore()
        let identity = try makeIdentity()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: identity.inboxId, clientId: identity.clientId,
            ethAddress: "0xabc", deviceId: "device-1"
        ))

        let events = EventLog()
        var config = Config(identity: identity)
        config.mint = { _ in throw SIWEAuthError.identityDeleted }
        config.deletion = { _, _ in
            Issue.record("Deletion endpoint must not be called after the terminal mint response")
            throw APIError.invalidRequest
        }
        let service = makeService(store: store, events: events, config: config)

        await service.recoverAtLaunch()
        #expect(store.load().activeRecord == nil)
        #expect(events.contains("revoke(phase: backend_confirmed)"))
        #expect(events.events.contains(where: { $0.hasPrefix("wipe(") }))
        #expect(events.events.last == "reauthSuspended(false)")
    }

    @Test("A 200 echoing a different stored operationId still confirms")
    func mismatchedOperationIdStillConfirms() async throws {
        let store = try makeStore()
        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.deletion = { _, _ in
            ConvosAPI.AccountDeletionResponse(
                status: "deleted",
                operationId: UUID().uuidString.lowercased(),
                deletedAt: Date(),
                purgeWindowHours: 24
            )
        }
        let service = makeService(store: store, events: events, config: config)

        try await service.deleteAccount { _ in }
        #expect(store.load().activeRecord == nil)
    }

    // MARK: - Recovery matrix

    @Test("Recovery with no record does nothing")
    func recoveryNoRecord() async throws {
        let store = try makeStore()
        let events = EventLog()
        let service = makeService(store: store, events: events, config: Config(identity: try makeIdentity()))

        await service.recoverAtLaunch()
        #expect(events.events.isEmpty)
    }

    @Test("Recovery from requested retries the same operationId")
    func recoveryRequestedRetriesSameOperation() async throws {
        let store = try makeStore()
        let identity = try makeIdentity()
        let operationId = UUID()
        try await store.begin(AccountDeletionRecord(
            operationId: operationId, inboxId: identity.inboxId, clientId: identity.clientId,
            ethAddress: "0xabc", deviceId: "device-1"
        ))

        let events = EventLog()
        let service = makeService(store: store, events: events, config: Config(identity: identity))

        await service.recoverAtLaunch()
        #expect(events.events.contains(where: { $0.hasPrefix("delete(\(operationId.uuidString.lowercased())") }))
        #expect(store.load().activeRecord == nil)
    }

    @Test("Recovery from backendConfirmed resumes with revocation, no backend auth")
    func recoveryBackendConfirmedResumes() async throws {
        let store = try makeStore()
        let identity = try makeIdentity()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: identity.inboxId, clientId: identity.clientId,
            ethAddress: "0xabc", deviceId: "device-1"
        ))
        try await store.advance(to: .backendConfirmed)

        let events = EventLog()
        var config = Config(identity: identity)
        config.mint = { _ in
            Issue.record("No mint should happen when resuming a confirmed deletion")
            throw APIError.invalidRequest
        }
        let service = makeService(store: store, events: events, config: config)

        await service.recoverAtLaunch()
        #expect(events.contains("revoke(phase: backend_confirmed)"))
        #expect(store.load().activeRecord == nil)
    }

    @Test("Recovery from localWipePending skips revocation and completes the wipe")
    func recoveryLocalWipePendingSkipsRevocation() async throws {
        let store = try makeStore()
        let identity = try makeIdentity()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: identity.inboxId, clientId: identity.clientId,
            ethAddress: "0xabc", deviceId: "device-1"
        ))
        try await store.advance(to: .backendConfirmed)
        try await store.advance(to: .localWipePending)

        let events = EventLog()
        let service = makeService(store: store, events: events, config: Config(identity: identity))

        await service.recoverAtLaunch()
        #expect(!events.events.contains(where: { $0.hasPrefix("revoke(") }))
        #expect(events.events.contains(where: { $0.hasPrefix("wipe(") }))
        #expect(store.load().activeRecord == nil)
    }

    @Test("Recovery from a corrupt record holds re-auth and waits for explicit action")
    func recoveryCorruptRecordHolds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-deletion-service-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("account-deletion-record.json"))
        let store = AccountDeletionStateStore(directoryURL: directory)

        let events = EventLog()
        let service = makeService(store: store, events: events, config: Config(identity: try makeIdentity()))

        await service.recoverAtLaunch()
        #expect(events.events == ["reauthSuspended(true)"])
    }

    // MARK: - Wipe resume

    @Test("An incomplete wipe keeps the record; a later run completes and clears it")
    func incompleteWipeResumes() async throws {
        let store = try makeStore()
        let identity = try makeIdentity()

        let events = EventLog()
        var config = Config(identity: identity)
        config.failingEntries = [.imageCaches]
        let failingService = makeService(store: store, events: events, config: config)

        await #expect(throws: AccountDeletionError.self) {
            try await failingService.deleteAccount { _ in }
        }
        #expect(store.load().activeRecord?.phase == .localWipePending)

        // Next launch: the failing entry recovers; the resume completes.
        config.failingEntries = []
        let healthyService = makeService(store: store, events: events, config: config)
        await healthyService.recoverAtLaunch()
        #expect(store.load().activeRecord == nil)
    }

    @Test("deleteAccount on an already-confirmed record resumes without re-requesting")
    func deleteAccountResumesConfirmedRecord() async throws {
        let store = try makeStore()
        let identity = try makeIdentity()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: identity.inboxId, clientId: identity.clientId,
            ethAddress: "0xabc", deviceId: "device-1"
        ))
        try await store.advance(to: .backendConfirmed)

        let events = EventLog()
        var config = Config(identity: identity)
        config.deletion = { _, _ in
            Issue.record("No re-request when resuming a confirmed record")
            throw APIError.invalidRequest
        }
        let service = makeService(store: store, events: events, config: config)

        try await service.deleteAccount { _ in }
        #expect(store.load().activeRecord == nil)
    }

    @Test("deleteAccount without an identity fails honestly, nothing written")
    func deleteAccountWithoutIdentityFails() async throws {
        let store = try makeStore()
        let events = EventLog()
        let service = makeService(store: store, events: events, config: Config(identity: nil))

        await #expect(throws: AccountDeletionError.self) {
            try await service.deleteAccount { _ in }
        }
        #expect(store.load().activeRecord == nil)
        #expect(!events.events.contains(where: { $0.hasPrefix("wipe(") }))
    }

    // MARK: - Identity binding

    @Test("Recovery never mints or wipes with an identity that does not match the record")
    func recoveryRefusesMismatchedIdentity() async throws {
        let store = try makeStore()
        // Record for identity A; the keychain now holds identity B
        // (pairing displaced A while its deletion was pending).
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: "inbox-A", clientId: "client-A",
            ethAddress: "0xaaa", deviceId: "device-1"
        ))

        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.mint = { _ in
            Issue.record("Must never mint with an identity that does not match the record")
            throw APIError.invalidRequest
        }
        let service = makeService(store: store, events: events, config: config)

        await service.recoverAtLaunch()
        // No full wipe (identity B's data must survive), only the old
        // record's scoped slots; the live identity's re-auth resumes.
        #expect(!events.events.contains(where: { $0.hasPrefix("wipe(") }))
        #expect(!events.contains("stopServices"))
        #expect(events.contains("sweepRecordScopedSlots(inbox-A)"))
        #expect(events.events.last == "reauthSuspended(false)")
        #expect(store.load().activeRecord == nil)
    }

    @Test("A displaced record still confirms its backend deletion via a surviving cached token")
    func displacedRecordConfirmsWithCachedToken() async throws {
        let store = try makeStore()
        let operationId = UUID()
        try await store.begin(AccountDeletionRecord(
            operationId: operationId, inboxId: "inbox-A", clientId: "client-A",
            ethAddress: "0xaaa", deviceId: "device-1"
        ))

        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.cachedToken = { record in
            record.inboxId == "inbox-A" ? "cached-jwt-A" : nil
        }
        let service = makeService(store: store, events: events, config: config)

        await service.recoverAtLaunch()
        #expect(events.events.contains(where: { $0.hasPrefix("delete(\(operationId.uuidString.lowercased())") && $0.contains("jwt: cached-jwt-A") }))
        // Confirmed for the old account, but never the full local wipe:
        // the device now belongs to identity B.
        #expect(!events.events.contains(where: { $0.hasPrefix("wipe(") }))
        #expect(store.load().activeRecord == nil)
    }

    @Test("A confirmed record whose identity was displaced never runs the full manifest")
    func displacedConfirmedRecordSkipsFullWipe() async throws {
        let store = try makeStore()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: "inbox-A", clientId: "client-A",
            ethAddress: "0xaaa", deviceId: "device-1"
        ))
        try await store.advance(to: .backendConfirmed)

        let events = EventLog()
        let service = makeService(store: store, events: events, config: Config(identity: try makeIdentity()))

        await service.recoverAtLaunch()
        #expect(!events.events.contains(where: { $0.hasPrefix("wipe(") }))
        #expect(!events.events.contains(where: { $0.hasPrefix("revoke(") }))
        #expect(events.contains("sweepRecordScopedSlots(inbox-A)"))
        #expect(store.load().activeRecord == nil)
    }

    // MARK: - Missing identity holds

    @Test("Requested record with no identity and no cached token holds: no wipe, no clear")
    func requestedWithoutIdentityHolds() async throws {
        let store = try makeStore()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: "inbox-1", clientId: "client-1",
            ethAddress: "0xabc", deviceId: "device-1"
        ))

        let events = EventLog()
        let service = makeService(store: store, events: events, config: Config(identity: nil))

        await service.recoverAtLaunch()
        #expect(store.load().activeRecord?.phase == .requested)
        #expect(!events.events.contains(where: { $0.hasPrefix("wipe(") }))
        #expect(!events.contains("stopServices"))
        // Re-auth stays suspended while the unresolved record holds.
        #expect(events.events.last != "reauthSuspended(false)")
    }

    @Test("Requested record with no identity confirms via a surviving cached token, then wipes")
    func requestedWithoutIdentityConfirmsWithCachedToken() async throws {
        let store = try makeStore()
        let operationId = UUID()
        try await store.begin(AccountDeletionRecord(
            operationId: operationId, inboxId: "inbox-1", clientId: "client-1",
            ethAddress: "0xabc", deviceId: "device-1"
        ))

        let events = EventLog()
        var config = Config(identity: nil)
        config.cachedToken = { _ in "cached-jwt" }
        let service = makeService(store: store, events: events, config: config)

        await service.recoverAtLaunch()
        #expect(events.events.contains(where: { $0.hasPrefix("delete(\(operationId.uuidString.lowercased())") && $0.contains("jwt: cached-jwt") }))
        #expect(events.events.contains(where: { $0.hasPrefix("wipe(") }))
        #expect(store.load().activeRecord == nil)
    }

    // MARK: - Single flight

    @Test("Concurrent entry points single-flight: one backend request, one wipe")
    func concurrentRunsSingleFlight() async throws {
        let store = try makeStore()
        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.deletion = { operationId, _ in
            // Hold the first run mid-request so the second caller arrives
            // while it is in flight.
            try await Task.sleep(nanoseconds: 100_000_000)
            return ConvosAPI.AccountDeletionResponse(
                status: "deleted",
                operationId: operationId.uuidString.lowercased(),
                deletedAt: Date(),
                purgeWindowHours: 24
            )
        }
        let service = makeService(store: store, events: events, config: config)

        async let first: Void = service.deleteAccount { _ in }
        async let second: Void = service.recoverAtLaunch()
        try await first
        await second

        let deleteCalls = events.events.filter { $0.hasPrefix("delete(") }
        #expect(deleteCalls.count == 1)
        let wipeRuns = events.events.filter { $0 == "wipe(\(WipeManifestEntry.databaseRows.rawValue))" }
        #expect(wipeRuns.count == 1)
        #expect(store.load().activeRecord == nil)
    }

    // MARK: - Suspension consistency

    @Test("A failed record write releases the reauth suspension")
    func beginFailureReleasesSuspension() async throws {
        // Store rooted in a directory that does not exist: the initial
        // record write fails.
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-deletion-missing-\(UUID().uuidString)", isDirectory: true)
        let store = AccountDeletionStateStore(directoryURL: missingDirectory)

        let events = EventLog()
        let service = makeService(store: store, events: events, config: Config(identity: try makeIdentity()))

        await #expect(throws: (any Error).self) {
            try await service.deleteAccount { _ in }
        }
        #expect(events.events.last == "reauthSuspended(false)")
        #expect(!events.events.contains(where: { $0.hasPrefix("delete(") }))
    }
}
