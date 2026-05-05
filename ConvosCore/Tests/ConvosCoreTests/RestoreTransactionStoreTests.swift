@testable import ConvosCore
import Foundation
import Testing

@Suite("RestoreTransactionStore Tests")
struct RestoreTransactionStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "convos.tests.RestoreTransaction.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("load returns nil when nothing is saved")
    func testLoadDefault() {
        let defaults = freshDefaults()
        #expect(RestoreTransactionStore.load(defaults: defaults) == nil)
    }

    @Test("save then load round-trips the full record")
    func testRoundTrip() {
        let defaults = freshDefaults()
        let record = RestoreTransaction(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            phase: .databaseReplaced
        )
        RestoreTransactionStore.save(record, defaults: defaults)
        let loaded = RestoreTransactionStore.load(defaults: defaults)
        #expect(loaded == record)
    }

    @Test("clear removes the record")
    func testClear() {
        let defaults = freshDefaults()
        let record = RestoreTransaction()
        RestoreTransactionStore.save(record, defaults: defaults)
        RestoreTransactionStore.clear(defaults: defaults)
        #expect(RestoreTransactionStore.load(defaults: defaults) == nil)
    }
}

@Suite("PendingArchiveImportFailureStorage Tests")
struct PendingArchiveImportFailureStorageTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "convos.tests.PendingArchiveImport.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("load returns nil when nothing is saved")
    func testLoadDefault() {
        let defaults = freshDefaults()
        #expect(PendingArchiveImportFailureStorage.load(defaults: defaults) == nil)
    }

    @Test("save then load round-trips the failure summary")
    func testRoundTrip() {
        let defaults = freshDefaults()
        let failure = PendingArchiveImportFailure(
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            reason: "SDK version skew"
        )
        PendingArchiveImportFailureStorage.save(failure, defaults: defaults)
        #expect(PendingArchiveImportFailureStorage.load(defaults: defaults) == failure)
    }

    @Test("clear removes the record")
    func testClear() {
        let defaults = freshDefaults()
        PendingArchiveImportFailureStorage.save(
            PendingArchiveImportFailure(reason: "x"),
            defaults: defaults
        )
        PendingArchiveImportFailureStorage.clear(defaults: defaults)
        #expect(PendingArchiveImportFailureStorage.load(defaults: defaults) == nil)
    }
}
