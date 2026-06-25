@testable import Convos
import ConvosCore
import XCTest

/// Coverage for the agent builder's prompt-hint cache: disk hydration on
/// init, refresh-overwrites-on-success, retain-last-good-on-failure, and the
/// empty-payload / sanitize guards.
@MainActor
final class PromptHintsModelTests: XCTestCase {
    /// In-memory `PromptHintsDiskCache` double recording the last saved value.
    private final class DiskSpy {
        var stored: [String]
        var saved: [String]?

        init(stored: [String]) {
            self.stored = stored
        }

        var cache: PromptHintsDiskCache {
            PromptHintsDiskCache(
                load: { [weak self] in self?.stored ?? [] },
                save: { [weak self] hints in self?.saved = hints }
            )
        }
    }

    private struct SampleError: Error {}

    private func makeModel(
        service: (any PromptHintsServiceProtocol)?,
        disk: DiskSpy
    ) -> PromptHintsModel {
        PromptHintsModel(service: service, store: disk.cache, backoffSeconds: { _ in 0 })
    }

    func testHydratesFromDiskOnInit() {
        let disk = DiskSpy(stored: ["cached one", "cached two"])
        let model = makeModel(service: MockPromptHintsService(), disk: disk)
        XCTAssertEqual(model.hints, ["cached one", "cached two"],
                       "Init should hydrate the in-memory hints from disk")
    }

    func testRefreshOverwritesMemoryAndDiskOnSuccess() async {
        let disk = DiskSpy(stored: ["old"])
        let model = makeModel(service: MockPromptHintsService(hints: ["new one", "new two"]), disk: disk)
        await model.loadOnLaunch()
        XCTAssertEqual(model.hints, ["new one", "new two"], "A successful fetch overwrites memory")
        XCTAssertEqual(disk.saved, ["new one", "new two"], "A successful fetch overwrites disk")
    }

    func testRetainsLastGoodOnFetchFailure() async {
        let disk = DiskSpy(stored: ["cached"])
        let model = makeModel(service: MockPromptHintsService(error: SampleError()), disk: disk)
        await model.loadOnLaunch()
        XCTAssertEqual(model.hints, ["cached"], "A failed refetch must retain the last good hints")
        XCTAssertNil(disk.saved, "A failed refetch must not overwrite disk")
    }

    func testEmptyPayloadDoesNotWipeCache() async {
        let disk = DiskSpy(stored: ["cached"])
        let model = makeModel(service: MockPromptHintsService(hints: []), disk: disk)
        await model.loadOnLaunch()
        XCTAssertEqual(model.hints, ["cached"], "An empty payload must not wipe a good cache")
        XCTAssertNil(disk.saved, "An empty payload must not overwrite disk")
    }

    func testSanitizeTrimsDropsEmptyAndClamps() async {
        let long = String(repeating: "x", count: 300)
        let disk = DiskSpy(stored: [])
        let model = makeModel(service: MockPromptHintsService(hints: ["  spaced  ", "", long]), disk: disk)
        await model.loadOnLaunch()
        XCTAssertEqual(model.hints.count, 2, "Empty / whitespace-only hints are dropped")
        XCTAssertEqual(model.hints.first, "spaced", "Hints are trimmed")
        XCTAssertEqual(model.hints.last?.count, 240, "Hints are clamped to the 240-char contract")
    }

    func testLoadOnLaunchRunsOnlyOnce() async {
        let disk = DiskSpy(stored: [])
        let service = MockPromptHintsService(hints: ["one"])
        let model = makeModel(service: service, disk: disk)
        await model.loadOnLaunch()
        await model.loadOnLaunch()
        XCTAssertEqual(service.fetchCount, 1, "The launch refresh should fetch at most once per process")
    }
}
