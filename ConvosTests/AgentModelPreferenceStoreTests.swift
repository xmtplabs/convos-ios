@testable import Convos
import Foundation
import XCTest

final class AgentModelPreferenceStoreTests: XCTestCase {
    func testSelectionDefaultsToGPT56Sol() {
        let context: TestContext = makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

        XCTAssertEqual(context.store.selection(for: "space-abilities"), .gpt56Sol)
    }

    func testSelectionPersistsPerAgent() {
        let context: TestContext = makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

        context.store.save(.claudeFable, for: "space-abilities")
        context.store.save(.droc46, for: "flight-tracker")

        XCTAssertEqual(context.store.selection(for: "space-abilities"), .claudeFable)
        XCTAssertEqual(context.store.selection(for: "flight-tracker"), .droc46)
    }

    func testUnknownStoredModelFallsBackSafely() {
        let context: TestContext = makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        context.defaults.set("retired-model", forKey: "prototype.agent-model.space-abilities")

        XCTAssertEqual(context.store.selection(for: "space-abilities"), .gpt56Sol)
    }

    private func makeContext() -> TestContext {
        let suiteName: String = "AgentModelPreferenceStoreTests.\(UUID().uuidString)"
        let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
        return TestContext(
            suiteName: suiteName,
            defaults: defaults,
            store: AgentModelPreferenceStore(defaults: defaults)
        )
    }
}

private struct TestContext {
    let suiteName: String
    let defaults: UserDefaults
    let store: AgentModelPreferenceStore
}
