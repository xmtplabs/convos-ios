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

    private struct KeychainReadFailure: Error {}

    private struct Config {
        var identity: KeychainIdentity?
        /// When set, wins over `identity`: lets a test change the loadable
        /// identity mid-flow (e.g. the wipe emptying the keychain) or make
        /// the read itself fail.
        var identityProvider: (@Sendable () throws -> KeychainIdentity?)?
        var mint: @Sendable (KeychainIdentity) async throws -> String = { _ in "jwt" }
        var deletion: (@Sendable (UUID, String) async throws -> ConvosAPI.AccountDeletionResponse)?
        var failingEntries: Set<WipeManifestEntry> = []
        var wipeHandler: (@Sendable (WipeManifestEntry) async throws -> Void)?
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
        let loadIdentity: @Sendable () throws -> KeychainIdentity? = config.identityProvider ?? { identity }
        let mint = config.mint
        let wipeHandler = config.wipeHandler
        let cachedToken = config.cachedToken
        let ethAddress = config.ethAddress
        let dependencies = AccountDeletionDependencies(
            loadIdentity: { try loadIdentity() },
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
                        try await wipeHandler?(entry)
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
        try await store.markSendAttempted()

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
        try await store.markSendAttempted()

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
        try await store.markSendAttempted()

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
        try await store.markSendAttempted()

        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.mint = { _ in
            Issue.record("Must never mint with an identity that does not match the record")
            throw APIError.invalidRequest
        }
        let service = makeService(store: store, events: events, config: config)

        await service.recoverAtLaunch()
        // No full wipe (identity B's data must survive), and without a
        // backend confirmation the old record is held: its slots stay (the
        // cached-token slot is the only remaining confirmation channel)
        // and the record survives for a later retry. The live identity's
        // re-auth resumes.
        #expect(!events.events.contains(where: { $0.hasPrefix("wipe(") }))
        #expect(!events.contains("stopServices"))
        #expect(!events.events.contains(where: { $0.hasPrefix("sweepRecordScopedSlots(") }))
        #expect(events.events.last == "reauthSuspended(false)")
        #expect(store.load().activeRecord?.phase == .requested)
    }

    @Test("An unconfirmed displaced record holds and fails a new delete instead of being abandoned")
    func unconfirmedDisplacedRecordHoldsAndFailsUserDelete() async throws {
        let store = try makeStore()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: "inbox-A", clientId: "client-A",
            ethAddress: "0xaaa", deviceId: "device-1"
        ))

        let events = EventLog()
        let config = Config(identity: try makeIdentity())
        let service = makeService(store: store, events: events, config: config)

        do {
            try await service.deleteAccount { _ in }
            Issue.record("Expected displacedRecordUnresolved")
        } catch AccountDeletionError.displacedRecordUnresolved {
            // Expected: the joiner fails with a retry path.
        }
        // The old record survives untouched (no sweep, no clear) and no
        // deletion ran for either account.
        #expect(store.load().activeRecord?.inboxId == "inbox-A")
        #expect(!events.events.contains(where: { $0.hasPrefix("sweepRecordScopedSlots(") }))
        #expect(!events.events.contains(where: { $0.hasPrefix("delete(") }))
        #expect(!events.events.contains(where: { $0.hasPrefix("wipe(") }))
        #expect(events.events.last == "reauthSuspended(false)")
    }

    @Test("A displaced record whose cached-token confirmation fails is held, not cleared")
    func displacedRecordFailedConfirmationHolds() async throws {
        let store = try makeStore()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: "inbox-A", clientId: "client-A",
            ethAddress: "0xaaa", deviceId: "device-1"
        ))
        try await store.markSendAttempted()

        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.cachedToken = { _ in "cached-jwt-A" }
        config.deletion = { _, _ in throw APIError.serverError("boom") }
        let service = makeService(store: store, events: events, config: config)

        await service.recoverAtLaunch()
        #expect(store.load().activeRecord?.inboxId == "inbox-A")
        #expect(!events.events.contains(where: { $0.hasPrefix("sweepRecordScopedSlots(") }))
        #expect(!events.events.contains(where: { $0.hasPrefix("wipe(") }))
    }

    @Test("A displaced confirmation that cannot be persisted keeps the record and its slots")
    func displacedConfirmationPersistFailureKeepsSlots() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-deletion-service-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AccountDeletionStateStore(directoryURL: directory)
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: "inbox-A", clientId: "client-A",
            ethAddress: "0xaaa", deviceId: "device-1"
        ))
        try await store.markSendAttempted()

        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.cachedToken = { _ in "cached-jwt-A" }
        config.deletion = { operationId, _ in
            // The backend confirms, but the confirmation cannot be
            // persisted (store directory locked before returning).
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            return ConvosAPI.AccountDeletionResponse(
                status: "deleted",
                operationId: operationId.uuidString.lowercased(),
                deletedAt: Date(),
                purgeWindowHours: 24
            )
        }
        let service = makeService(store: store, events: events, config: config)

        await service.recoverAtLaunch()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        // With the confirmation unpersisted, the cached-token slot is the
        // record's only recovery channel: it must survive, and the record
        // must hold for a later retry.
        #expect(!events.events.contains(where: { $0.hasPrefix("sweepRecordScopedSlots(") }))
        #expect(store.load().activeRecord?.phase == .requested)
    }

    @Test("A displaced record still confirms its backend deletion via a surviving cached token")
    func displacedRecordConfirmsWithCachedToken() async throws {
        let store = try makeStore()
        let operationId = UUID()
        try await store.begin(AccountDeletionRecord(
            operationId: operationId, inboxId: "inbox-A", clientId: "client-A",
            ethAddress: "0xaaa", deviceId: "device-1"
        ))
        try await store.markSendAttempted()

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

    @Test("Remote wipe advances a reused requested record before teardown so a crash resumes from backendConfirmed")
    func remoteWipeAdvancesRequestedRecordBeforeTeardown() async throws {
        let store = try makeStore()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: "inbox-1", clientId: "client-1",
            ethAddress: "0xabc", deviceId: "device-1"
        ))
        try await store.markSendAttempted()

        let events = EventLog()
        let service = makeService(store: store, events: events, config: Config(identity: try makeIdentity()))

        let progressLog = EventLog()
        try await service.wipeAfterRemoteDeletion { progressLog.record("\($0)") }

        // The reused requested record was advanced to backendConfirmed, so
        // revocation runs from that phase and the durable phase reflects the
        // wipe. Without the advance, teardown would run the wipe while the
        // record still said requested, and a crash mid-wipe would hold forever.
        #expect(events.contains("revoke(phase: backend_confirmed)"))
        #expect(progressLog.contains("revokingDevices"))
        #expect(events.events.contains(where: { $0.hasPrefix("wipe(") }))
        #expect(store.load().activeRecord == nil)
    }

    @Test("A displaced requested record with no send marker holds and is never auto-sent, even with a cached token")
    func displacedUnmarkedRecordHoldsAndNeverSends() async throws {
        let store = try makeStore()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: "inbox-A", clientId: "client-A",
            ethAddress: "0xaaa", deviceId: "device-1"
        ))
        // Deliberately not marked send-attempted: the request was provably
        // never sent, so the old backend account is still alive.

        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.cachedToken = { _ in "cached-jwt-A" }
        let service = makeService(store: store, events: events, config: config)

        do {
            try await service.deleteAccount { _ in }
            Issue.record("Expected displacedRecordUnresolved")
        } catch AccountDeletionError.displacedRecordUnresolved {
            // Expected: the unmarked displaced record is held, not sent.
        }
        // The invariant: an unmarked record is never auto-sent, even when
        // displaced with a surviving cached token, and its synced backup
        // (the live account's iCloud recovery channel) is left untouched.
        #expect(!events.events.contains(where: { $0.hasPrefix("delete(") }))
        #expect(!events.events.contains(where: { $0.hasPrefix("sweepRecordScopedSlots(") }))
        #expect(store.load().activeRecord?.inboxId == "inbox-A")
    }

    @Test("A confirmed teardown resume with an unreadable keychain fails retryably, never running the full manifest")
    func confirmedResumeKeychainReadErrorHoldsWithoutWipe() async throws {
        let store = try makeStore()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: "inbox-1", clientId: "client-1",
            ethAddress: "0xabc", deviceId: "device-1"
        ))
        try await store.advance(to: .backendConfirmed)

        let events = EventLog()
        var config = Config(identity: nil)
        config.identityProvider = { throw KeychainReadFailure() }
        let service = makeService(store: store, events: events, config: config)

        do {
            try await service.deleteAccount { _ in }
            Issue.record("Expected identityUnavailable")
        } catch AccountDeletionError.identityUnavailable {
            // Expected: an unreadable keychain is not proof the identity is
            // unchanged, so the full manifest must not run against it.
        }
        #expect(!events.events.contains(where: { $0.hasPrefix("wipe(") }))
        #expect(store.load().activeRecord?.phase == .backendConfirmed)
    }

    // MARK: - Missing identity holds

    @Test("Requested record with no identity and no cached token holds: no wipe, no clear")
    func requestedWithoutIdentityHolds() async throws {
        let store = try makeStore()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: "inbox-1", clientId: "client-1",
            ethAddress: "0xabc", deviceId: "device-1"
        ))
        try await store.markSendAttempted()

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
        try await store.markSendAttempted()

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

    @Test("A delete arriving during a hold-only recovery run fails honestly instead of reporting the recovery's success")
    func deleteDuringHoldOnlyRecoveryFails() async throws {
        let store = try makeStore()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: "inbox-1", clientId: "client-1",
            ethAddress: "0xabc", deviceId: "device-1"
        ))
        try await store.markSendAttempted()

        let events = EventLog()
        var config = Config(identity: nil)
        config.cachedToken = { _ in "cached-jwt" }
        config.deletion = { _, _ in
            // Slow failing confirmation: recovery ends up holding the
            // record, and the delete arrives while recovery is in flight.
            try await Task.sleep(nanoseconds: 150_000_000)
            throw APIError.serverError("boom")
        }
        let service = makeService(store: store, events: events, config: config)

        async let recovery: Void = service.recoverAtLaunch()
        try await Task.sleep(nanoseconds: 30_000_000)
        await #expect(throws: AccountDeletionError.self) {
            try await service.deleteAccount { _ in }
        }
        await recovery
        // The record is still unresolved; nothing was wiped and the delete
        // caller was not told otherwise.
        #expect(store.load().activeRecord?.phase == .requested)
        #expect(!events.events.contains(where: { $0.hasPrefix("wipe(") }))
    }

    @Test("A delete serialized behind a completing recovery reports completion, not a false failure")
    func deleteBehindCompletingRecoveryReportsCompletion() async throws {
        let store = try makeStore()
        let identity = try makeIdentity()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: identity.inboxId, clientId: identity.clientId,
            ethAddress: "0xabc", deviceId: "device-1"
        ))
        try await store.markSendAttempted()

        let identityBox = OSAllocatedUnfairLock<KeychainIdentity?>(initialState: identity)
        let events = EventLog()
        var config = Config(identity: nil)
        config.identityProvider = { identityBox.withLock { $0 } }
        config.deletion = { operationId, _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return ConvosAPI.AccountDeletionResponse(
                status: "deleted",
                operationId: operationId.uuidString.lowercased(),
                deletedAt: Date(),
                purgeWindowHours: 24
            )
        }
        config.wipeHandler = { entry in
            if entry == .keychainIdentityFamily {
                identityBox.withLock { $0 = nil }
            }
        }
        let service = makeService(store: store, events: events, config: config)

        async let recovery: Void = service.recoverAtLaunch()
        try await Task.sleep(nanoseconds: 30_000_000)
        let progressLog = EventLog()
        try await service.deleteAccount { progressLog.record("\($0)") }
        await recovery

        // One backend request, one wipe; the serialized delete observed
        // the completed teardown instead of failing on the empty keychain.
        #expect(events.events.filter { $0.hasPrefix("delete(") }.count == 1)
        #expect(events.events.filter { $0 == "wipe(\(WipeManifestEntry.databaseRows.rawValue))" }.count == 1)
        #expect(progressLog.events.last == "completed")
        #expect(store.load().activeRecord == nil)
    }

    @Test("After a completed teardown, a keychain read error fails a delete retryably, never as false success")
    func completedTeardownKeychainReadErrorFailsDelete() async throws {
        let store = try makeStore()
        let identity = try makeIdentity()
        let failReads = OSAllocatedUnfairLock(initialState: false)
        let events = EventLog()
        var config = Config(identity: nil)
        config.identityProvider = {
            if failReads.withLock({ $0 }) { throw KeychainReadFailure() }
            return identity
        }
        let service = makeService(store: store, events: events, config: config)

        // First delete completes the teardown (sets the process marker).
        try await service.deleteAccount { _ in }
        #expect(store.load().activeRecord == nil)

        // The keychain becomes unreadable: a re-provisioned identity could
        // exist behind the error, so the next delete must fail retryably
        // instead of reporting the earlier completion as its own.
        failReads.withLock { $0 = true }
        let progressLog = EventLog()
        do {
            try await service.deleteAccount { progressLog.record("\($0)") }
            Issue.record("Expected identityUnavailable")
        } catch AccountDeletionError.identityUnavailable {
            // Expected: retryable, no success claimed.
        }
        #expect(!progressLog.contains("completed"))
        #expect(events.events.filter { $0.hasPrefix("delete(") }.count == 1)
    }

    @Test("After a completed teardown, a keychain read error fails a remote wipe retryably, never as false success")
    func completedTeardownKeychainReadErrorFailsRemoteWipe() async throws {
        let store = try makeStore()
        let identity = try makeIdentity()
        let failReads = OSAllocatedUnfairLock(initialState: false)
        let events = EventLog()
        var config = Config(identity: nil)
        config.identityProvider = {
            if failReads.withLock({ $0 }) { throw KeychainReadFailure() }
            return identity
        }
        let service = makeService(store: store, events: events, config: config)

        try await service.deleteAccount { _ in }
        let wipesAfterDelete = events.events.filter { $0 == "wipe(\(WipeManifestEntry.databaseRows.rawValue))" }.count
        #expect(wipesAfterDelete == 1)

        failReads.withLock { $0 = true }
        let progressLog = EventLog()
        do {
            try await service.wipeAfterRemoteDeletion { progressLog.record("\($0)") }
            Issue.record("Expected identityUnavailable")
        } catch AccountDeletionError.identityUnavailable {
            // Expected: retryable, no success claimed.
        }
        #expect(!progressLog.contains("completed"))
        #expect(events.events.filter { $0 == "wipe(\(WipeManifestEntry.databaseRows.rawValue))" }.count == wipesAfterDelete)
    }

    // MARK: - Local-reset gate

    @Test("Local reset is refused while a deletion record is active")
    func localResetRefusedWhileRecordActive() async throws {
        let store = try makeStore()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: "inbox-1", clientId: "client-1",
            ethAddress: "0xabc", deviceId: "device-1"
        ))

        let events = EventLog()
        let service = makeService(store: store, events: events, config: Config(identity: nil))

        let ran = OSAllocatedUnfairLock(initialState: false)
        await #expect(throws: AccountDeletionInProgressError.self) {
            try await service.performLocalResetIfIdle {
                ran.withLock { $0 = true }
            }
        }
        #expect(ran.withLock { $0 } == false)
        #expect(store.load().activeRecord?.phase == .requested)
    }

    @Test("Local reset serialized behind a failing deletion run is refused, closing the check-then-act race")
    func localResetDuringDeletionRunRefused() async throws {
        let store = try makeStore()
        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.deletion = { _, _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            throw APIError.serverError("boom")
        }
        let service = makeService(store: store, events: events, config: config)

        async let deletion: Void = {
            try? await service.deleteAccount { _ in }
        }()
        try await Task.sleep(nanoseconds: 30_000_000)
        let ran = OSAllocatedUnfairLock(initialState: false)
        await #expect(throws: AccountDeletionInProgressError.self) {
            try await service.performLocalResetIfIdle {
                ran.withLock { $0 = true }
            }
        }
        await deletion
        #expect(ran.withLock { $0 } == false)
        #expect(store.load().activeRecord?.phase == .requested)
    }

    @Test("Local reset runs when no deletion record exists")
    func localResetRunsWhenIdle() async throws {
        let store = try makeStore()
        let events = EventLog()
        let service = makeService(store: store, events: events, config: Config(identity: try makeIdentity()))

        let ran = OSAllocatedUnfairLock(initialState: false)
        try await service.performLocalResetIfIdle {
            ran.withLock { $0 = true }
        }
        #expect(ran.withLock { $0 })
    }

    // MARK: - Preflight-abort honesty

    @Test("Preflight failure with a stuck record throws the held error, never a clean failure")
    func preflightClearFailureThrowsHeldError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-deletion-service-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AccountDeletionStateStore(directoryURL: directory)

        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.mint = { _ in
            // Lock the store's directory before failing preflight, so the
            // subsequent record clear cannot remove the file.
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            throw SIWEAuthError.invalidNonceOrSignature(nil)
        }
        let service = makeService(store: store, events: events, config: config)

        do {
            try await service.deleteAccount { _ in }
            Issue.record("Expected preflightFailedRecordHeld")
        } catch AccountDeletionError.preflightFailedRecordHeld {
            // Expected: the caller learns the pending state is stuck.
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(store.load().activeRecord?.phase == .requested)
        // The account is alive and no deletion was sent; re-auth resumes.
        #expect(events.events.last == "reauthSuspended(false)")
        #expect(!events.events.contains(where: { $0.hasPrefix("delete(") }))

        // Worst case: neither the clear nor the abort marker could be
        // persisted (both writes hit the locked directory). The surviving
        // record has no send marker, so launch recovery must hold it and
        // never silently re-send the deletion the user was told failed.
        let recoveryEvents = EventLog()
        var recoveryConfig = Config(identity: try makeIdentity())
        recoveryConfig.mint = { _ in
            Issue.record("Recovery must never re-send a deletion whose failure the user saw")
            throw APIError.invalidRequest
        }
        recoveryConfig.deletion = { _, _ in
            Issue.record("Recovery must never re-send a deletion whose failure the user saw")
            throw APIError.invalidRequest
        }
        let recoveryService = makeService(store: store, events: recoveryEvents, config: recoveryConfig)
        await recoveryService.recoverAtLaunch()
        #expect(store.load().activeRecord?.phase == .requested)
        #expect(recoveryEvents.events.isEmpty)
    }

    @Test("A requested record without the send marker is held at launch, never auto-sent")
    func unsentRequestedRecordHeldAtLaunch() async throws {
        let store = try makeStore()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: "inbox-1", clientId: "client-1",
            ethAddress: "0xabc", deviceId: "device-1"
        ))

        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.mint = { _ in
            Issue.record("An unmarked record must never mint at launch")
            throw APIError.invalidRequest
        }
        config.deletion = { _, _ in
            Issue.record("An unmarked record must never be sent at launch")
            throw APIError.invalidRequest
        }
        let service = makeService(store: store, events: events, config: config)

        await service.recoverAtLaunch()
        // Held and surfaced (the settings pending row offers the explicit
        // retry); the account is alive so re-auth stays untouched.
        #expect(store.load().activeRecord?.phase == .requested)
        #expect(events.events.isEmpty)
    }

    // MARK: - Write-before-send invariant

    @Test("A record that goes missing before the send marker is written blocks the send")
    func missingRecordAtSendMarkerBlocksSend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-deletion-service-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountDeletionStateStore(directoryURL: directory)
        let recordFile = directory.appendingPathComponent("account-deletion-record.json")

        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.mint = { _ in
            // The record disappears between begin and the marker write.
            try? FileManager.default.removeItem(at: recordFile)
            return "jwt"
        }
        config.deletion = { _, _ in
            Issue.record("Nothing may be sent when the send marker provably did not persist")
            throw APIError.invalidRequest
        }
        let service = makeService(store: store, events: events, config: config)

        await #expect(throws: AccountDeletionError.self) {
            try await service.deleteAccount { _ in }
        }
        #expect(!events.events.contains(where: { $0.hasPrefix("delete(") }))
    }

    @Test("A record that becomes unreadable before the send marker is written blocks the send")
    func unreadableRecordAtSendMarkerBlocksSend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-deletion-service-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountDeletionStateStore(directoryURL: directory)
        let recordFile = directory.appendingPathComponent("account-deletion-record.json")

        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.mint = { _ in
            // The record turns to garbage between begin and the marker
            // write: unreadable, so the marker provably cannot persist.
            try? Data("not json {".utf8).write(to: recordFile)
            return "jwt"
        }
        config.deletion = { _, _ in
            Issue.record("Nothing may be sent when the send marker provably did not persist")
            throw APIError.invalidRequest
        }
        let service = makeService(store: store, events: events, config: config)

        await #expect(throws: AccountDeletionError.self) {
            try await service.deleteAccount { _ in }
        }
        #expect(!events.events.contains(where: { $0.hasPrefix("delete(") }))
    }

    @Test("A send-marker write failure blocks the send and holds the record")
    func failedSendMarkerWriteBlocksSend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-deletion-service-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AccountDeletionStateStore(directoryURL: directory)

        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.mint = { _ in
            // Mint succeeds, but the store becomes unwritable before the
            // marker write.
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            return "jwt"
        }
        config.deletion = { _, _ in
            Issue.record("Nothing may be sent when the send marker provably did not persist")
            throw APIError.invalidRequest
        }
        let service = makeService(store: store, events: events, config: config)

        do {
            try await service.deleteAccount { _ in }
            Issue.record("Expected preflightFailedRecordHeld")
        } catch AccountDeletionError.preflightFailedRecordHeld {
            // Expected: clear also failed, so the stuck record is reported.
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(!events.events.contains(where: { $0.hasPrefix("delete(") }))
        // The surviving record is unmarked, so launch recovery holds it.
        let survivor = store.load().activeRecord
        #expect(survivor?.phase == .requested)
        #expect(survivor?.sendAttempted == nil)
    }

    @Test("An aborted pre-send record is cleared at launch without re-sending the deletion")
    func abortedRecordClearsAtLaunchWithoutResending() async throws {
        let store = try makeStore()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: "inbox-1", clientId: "client-1",
            ethAddress: "0xabc", deviceId: "device-1"
        ))
        try await store.markPreflightAborted()

        let events = EventLog()
        var config = Config(identity: try makeIdentity())
        config.mint = { _ in
            Issue.record("An aborted record must never re-send the deletion at launch")
            throw APIError.invalidRequest
        }
        config.deletion = { _, _ in
            Issue.record("An aborted record must never re-send the deletion at launch")
            throw APIError.invalidRequest
        }
        let service = makeService(store: store, events: events, config: config)

        await service.recoverAtLaunch()
        #expect(store.load().activeRecord == nil)
        #expect(!events.events.contains(where: { $0.hasPrefix("wipe(") }))
        // The account is alive; recovery of an aborted record does not
        // suspend re-auth.
        #expect(!events.contains("reauthSuspended(true)"))
    }

    @Test("An explicit retry on an aborted record re-sends the deletion (user intent)")
    func abortedRecordExplicitRetryResends() async throws {
        let store = try makeStore()
        let identity = try makeIdentity()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(), inboxId: identity.inboxId, clientId: identity.clientId,
            ethAddress: "0xabc", deviceId: "device-1"
        ))
        try await store.markPreflightAborted()

        let events = EventLog()
        let service = makeService(store: store, events: events, config: Config(identity: identity))

        try await service.deleteAccount { _ in }
        #expect(events.events.contains(where: { $0.hasPrefix("delete(") }))
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
