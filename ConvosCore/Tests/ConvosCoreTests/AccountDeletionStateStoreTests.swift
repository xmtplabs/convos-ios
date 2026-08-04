@testable import ConvosCore
import Foundation
import Testing

/// Covers the durable deletion record and its file-backed store: phase
/// transition legality, round-trips, atomic overwrites, corrupt-file
/// tolerance, and clear-on-complete semantics.
@Suite("Account Deletion State Store")
struct AccountDeletionStateStoreTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-deletion-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRecord(
        operationId: UUID = UUID(),
        phase: AccountDeletionPhase = .requested
    ) -> AccountDeletionRecord {
        AccountDeletionRecord(
            operationId: operationId,
            inboxId: "inbox-1",
            clientId: "client-1",
            ethAddress: "0xAbCdEf0123456789aBcDeF0123456789AbCdEf01",
            deviceId: "device-1",
            // Whole seconds: ISO 8601 round-trips truncate sub-second
            // precision, and these tests compare full-record equality.
            requestedAt: Date(timeIntervalSince1970: 1_752_500_000),
            phase: phase
        )
    }

    // MARK: - Record transitions

    @Test("Phase transition matrix: forward and same-phase allowed, backward rejected")
    func phaseTransitionMatrix() {
        #expect(AccountDeletionPhase.requested.canTransition(to: .backendConfirmed))
        #expect(AccountDeletionPhase.backendConfirmed.canTransition(to: .localWipePending))
        for phase in AccountDeletionPhase.allCases {
            #expect(phase.canTransition(to: phase))
        }
        #expect(!AccountDeletionPhase.requested.canTransition(to: .localWipePending))
        #expect(!AccountDeletionPhase.backendConfirmed.canTransition(to: .requested))
        #expect(!AccountDeletionPhase.localWipePending.canTransition(to: .requested))
        #expect(!AccountDeletionPhase.localWipePending.canTransition(to: .backendConfirmed))
    }

    @Test("Advancing stamps phase timestamps once")
    func advancedStampsTimestamps() throws {
        let record = makeRecord()
        #expect(record.backendConfirmedAt == nil)
        #expect(record.wipeStartedAt == nil)

        let firstConfirmation = Date(timeIntervalSince1970: 100)
        let confirmed = try record.advanced(to: .backendConfirmed, at: firstConfirmation)
        #expect(confirmed.backendConfirmedAt == firstConfirmation)

        // Idempotent re-advance keeps the original timestamp.
        let reconfirmed = try confirmed.advanced(to: .backendConfirmed, at: Date(timeIntervalSince1970: 200))
        #expect(reconfirmed.backendConfirmedAt == firstConfirmation)

        let wipeStart = Date(timeIntervalSince1970: 300)
        let wiping = try reconfirmed.advanced(to: .localWipePending, at: wipeStart)
        #expect(wiping.wipeStartedAt == wipeStart)
        #expect(wiping.backendConfirmedAt == firstConfirmation)
    }

    @Test("Illegal record advance throws")
    func illegalAdvanceThrows() throws {
        let record = makeRecord()
        #expect(throws: AccountDeletionStateStoreError.invalidTransition(from: .requested, to: .localWipePending)) {
            try record.advanced(to: .localWipePending)
        }
    }

    @Test("Record normalizes the Ethereum address to lowercase")
    func addressIsLowercased() {
        let record = makeRecord()
        #expect(record.ethAddress == record.ethAddress.lowercased())
    }

    // MARK: - Store

    @Test("Empty directory loads as none and does not block provisioning")
    func emptyLoadsAsNone() throws {
        let store = AccountDeletionStateStore(directoryURL: try makeTempDirectory())
        let result = store.load()
        #expect(result.activeRecord == nil)
        #expect(!result.blocksIdentityProvisioning)
    }

    @Test("Begin then load round-trips the record")
    func beginRoundTrips() async throws {
        let store = AccountDeletionStateStore(directoryURL: try makeTempDirectory())
        let record = makeRecord()
        try await store.begin(record)

        let loaded = store.load()
        #expect(loaded.activeRecord == record)
        #expect(loaded.blocksIdentityProvisioning)
    }

    @Test("Begin is idempotent for the same operation id and rejects a different one")
    func beginIdempotency() async throws {
        let store = AccountDeletionStateStore(directoryURL: try makeTempDirectory())
        let record = makeRecord()
        try await store.begin(record)
        try await store.begin(record)

        let other = makeRecord()
        await #expect(throws: AccountDeletionStateStoreError.recordAlreadyExists(existingOperationId: record.operationId)) {
            try await store.begin(other)
        }
        #expect(store.load().activeRecord == record)
    }

    @Test("Advance persists each phase atomically over the previous record")
    func advancePersistsPhases() async throws {
        let store = AccountDeletionStateStore(directoryURL: try makeTempDirectory())
        let record = makeRecord()
        try await store.begin(record)

        let confirmed = try await store.advance(to: .backendConfirmed)
        #expect(confirmed.phase == .backendConfirmed)
        #expect(store.load().activeRecord?.phase == .backendConfirmed)

        let wiping = try await store.advance(to: .localWipePending)
        #expect(wiping.phase == .localWipePending)
        let final = store.load().activeRecord
        #expect(final?.phase == .localWipePending)
        #expect(final?.operationId == record.operationId)
    }

    @Test("Advance without a record throws")
    func advanceWithoutRecordThrows() async throws {
        let store = AccountDeletionStateStore(directoryURL: try makeTempDirectory())
        await #expect(throws: AccountDeletionStateStoreError.self) {
            try await store.advance(to: .backendConfirmed)
        }
    }

    @Test("Clear removes the record and is idempotent")
    func clearRemovesRecord() async throws {
        let store = AccountDeletionStateStore(directoryURL: try makeTempDirectory())
        try await store.begin(makeRecord())
        try await store.clear()
        #expect(store.load().activeRecord == nil)
        try await store.clear()
    }

    @Test("Corrupt file loads as corrupted, blocks provisioning, and is replaced by an explicit begin")
    func corruptFileFailsSafe() async throws {
        let directory = try makeTempDirectory()
        let fileURL = directory.appendingPathComponent("account-deletion-record.json")
        try Data("not json {".utf8).write(to: fileURL)

        let store = AccountDeletionStateStore(directoryURL: directory)
        let result = store.load()
        #expect(result.activeRecord == nil)
        #expect(result.blocksIdentityProvisioning)

        let record = makeRecord()
        try await store.begin(record)
        #expect(store.load().activeRecord == record)
    }

    @Test("Record survives store re-creation (cold-launch read)")
    func recordSurvivesStoreRecreation() async throws {
        let directory = try makeTempDirectory()
        let record = makeRecord()
        try await AccountDeletionStateStore(directoryURL: directory).begin(record)

        let reopened = AccountDeletionStateStore(directoryURL: directory)
        #expect(reopened.load().activeRecord == record)
    }

    @Test("Preflight-aborted marker round-trips and preserves the record")
    func preflightAbortedMarkerRoundTrips() async throws {
        let directory = try makeTempDirectory()
        let store = AccountDeletionStateStore(directoryURL: directory)
        let record = makeRecord()
        try await store.begin(record)
        #expect(store.load().activeRecord?.preflightAborted == nil)

        try await store.markPreflightAborted()

        let reopened = AccountDeletionStateStore(directoryURL: directory)
        let loaded = try #require(reopened.load().activeRecord)
        #expect(loaded.preflightAborted == true)
        #expect(loaded.phase == .requested)
        #expect(loaded.operationId == record.operationId)
    }

    @Test("Send-attempted marker round-trips in one atomic write and preserves the record")
    func sendAttemptedMarkerRoundTrips() async throws {
        let directory = try makeTempDirectory()
        let store = AccountDeletionStateStore(directoryURL: directory)
        let record = makeRecord()
        try await store.begin(record)
        #expect(store.load().activeRecord?.sendAttempted == nil)

        try await store.markSendAttempted()

        let reopened = AccountDeletionStateStore(directoryURL: directory)
        let loaded = try #require(reopened.load().activeRecord)
        #expect(loaded.sendAttempted == true)
        #expect(loaded.phase == .requested)
        #expect(loaded.operationId == record.operationId)
        // The marker survives phase advancement.
        let advanced = try await store.advance(to: .backendConfirmed)
        #expect(advanced.sendAttempted == true)
    }

    @Test("Send-attempted marking throws on a missing record: the marker provably did not persist")
    func sendAttemptedMarkingThrowsOnMissingRecord() async throws {
        let store = AccountDeletionStateStore(directoryURL: try makeTempDirectory())
        await #expect(throws: AccountDeletionStateStoreError.recordNotLoadable) {
            try await store.markSendAttempted()
        }
    }

    @Test("Send-attempted marking throws on an unreadable record: never a silent success")
    func sendAttemptedMarkingThrowsOnUnreadableRecord() async throws {
        let directory = try makeTempDirectory()
        try Data("not json {".utf8).write(to: directory.appendingPathComponent("account-deletion-record.json"))
        let store = AccountDeletionStateStore(directoryURL: directory)
        await #expect(throws: AccountDeletionStateStoreError.recordNotLoadable) {
            try await store.markSendAttempted()
        }
    }
}
