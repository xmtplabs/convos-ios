@testable import Convos
import Foundation
import XCTest

final class AgentModelPreferenceStoreTests: XCTestCase {
    func testPickerOffersTheFiveRequestedModelFamilies() {
        XCTAssertEqual(
            Set(AgentModelOption.allCases.map(\.displayName)),
            Set(["Grok", "Claude", "ChatGPT", "Gemini", "DeepSeek"])
        )
    }

    func testSelectionDefaultsToChatGPT() {
        let context: TestContext = makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

        XCTAssertEqual(context.store.selection(for: "space-abilities"), .chatGPT)
    }

    func testSelectionPersistsPerAgent() {
        let context: TestContext = makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

        context.store.save(.claude, for: "space-abilities")
        context.store.save(.deepSeek, for: "flight-tracker")

        XCTAssertEqual(context.store.selection(for: "space-abilities"), .claude)
        XCTAssertEqual(context.store.selection(for: "flight-tracker"), .deepSeek)
    }

    func testUnknownStoredModelFallsBackSafely() {
        let context: TestContext = makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        context.defaults.set("retired-model", forKey: "prototype.agent-model.space-abilities")

        XCTAssertEqual(context.store.selection(for: "space-abilities"), .chatGPT)
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
