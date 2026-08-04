@testable import ConvosCore
import Foundation
import Testing

/// Covers the wipe-manifest inventory and its executor: version fallback,
/// no-short-circuit execution, missing-handler accounting, and re-run
/// behavior for resume-after-crash.
@Suite("Wipe Manifest")
struct WipeManifestTests {
    private func makeRecord(wipeManifestVersion: Int = WipeManifest.currentVersion) -> AccountDeletionRecord {
        AccountDeletionRecord(
            operationId: UUID(),
            wipeManifestVersion: wipeManifestVersion,
            inboxId: "inbox-1",
            clientId: "client-1",
            ethAddress: "0xabc",
            deviceId: "device-1"
        )
    }

    private func makeHandlers(
        failing: Set<WipeManifestEntry> = [],
        recorder: WipeRunRecorder? = nil
    ) -> [WipeManifestEntry: WipeStep] {
        var handlers: [WipeManifestEntry: WipeStep] = [:]
        for entry in WipeManifestEntry.allCases {
            handlers[entry] = WipeStep { _ in
                await recorder?.record(entry)
                if failing.contains(entry) {
                    throw TestWipeError.boom
                }
            }
        }
        return handlers
    }

    @Test("Current manifest version inventories every entry exactly once")
    func currentVersionCoversAllEntries() {
        let entries = WipeManifest.entries(forVersion: WipeManifest.currentVersion)
        #expect(Set(entries) == Set(WipeManifestEntry.allCases))
        #expect(entries.count == WipeManifestEntry.allCases.count)
    }

    @Test("Unknown manifest versions fall back to the full current inventory")
    func unknownVersionFallsBack() {
        let entries = WipeManifest.entries(forVersion: 99)
        #expect(Set(entries) == Set(WipeManifestEntry.allCases))
    }

    @Test("A run with all handlers succeeding is complete and executes in manifest order")
    func fullRunCompletes() async {
        let recorder = WipeRunRecorder()
        let executor = WipeManifestExecutor(handlers: makeHandlers(recorder: recorder))
        let result = await executor.run(record: makeRecord())

        #expect(result.isComplete)
        #expect(result.failures.isEmpty)
        let ran = await recorder.entries
        #expect(ran == WipeManifest.entries(forVersion: WipeManifest.currentVersion))
    }

    @Test("A failing entry does not short-circuit the remaining entries")
    func failureDoesNotShortCircuit() async {
        let recorder = WipeRunRecorder()
        let executor = WipeManifestExecutor(
            handlers: makeHandlers(failing: [.keychainIdentityFamily], recorder: recorder)
        )
        let result = await executor.run(record: makeRecord())

        #expect(!result.isComplete)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.entry == .keychainIdentityFamily)
        let ran = await recorder.entries
        #expect(ran.count == WipeManifestEntry.allCases.count)
        #expect(result.executed.count == WipeManifestEntry.allCases.count - 1)
    }

    @Test("A missing handler is a failure, never a silent skip")
    func missingHandlerIsFailure() async {
        var handlers = makeHandlers()
        handlers[.analyticsIdentity] = nil
        let executor = WipeManifestExecutor(handlers: handlers)
        let result = await executor.run(record: makeRecord())

        #expect(!result.isComplete)
        #expect(result.failures.count == 1)
        let failure = result.failures.first
        #expect(failure?.entry == .analyticsIdentity)
        #expect(failure?.error as? WipeManifestExecutorError == .missingHandler(.analyticsIdentity))
    }

    @Test("A second run re-executes every entry (resume re-runs the whole manifest)")
    func secondRunReExecutes() async {
        let recorder = WipeRunRecorder()
        let executor = WipeManifestExecutor(handlers: makeHandlers(recorder: recorder))
        let record = makeRecord()
        _ = await executor.run(record: record)
        _ = await executor.run(record: record)

        let ran = await recorder.entries
        #expect(ran.count == WipeManifestEntry.allCases.count * 2)
    }
}

private enum TestWipeError: Error {
    case boom
}

private actor WipeRunRecorder {
    private(set) var entries: [WipeManifestEntry] = []

    func record(_ entry: WipeManifestEntry) {
        entries.append(entry)
    }
}
