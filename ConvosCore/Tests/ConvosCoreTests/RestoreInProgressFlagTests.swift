@testable import ConvosCore
import Foundation
import Testing

@Suite("RestoreInProgressFlag Tests")
struct RestoreInProgressFlagTests {
    private func freshDefaults() -> UserDefaults {
        // Scoped suite per-test so parallel runs don't collide.
        let suite = "convos.tests.RestoreInProgressFlag.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("is absent by default on a fresh suite")
    func testDefaultFalse() {
        let defaults = freshDefaults()
        #expect(RestoreInProgressFlag.isSet(defaults: defaults) == false)
    }

    @Test("set to true then read returns true")
    func testSetTrueRoundTrip() {
        let defaults = freshDefaults()
        RestoreInProgressFlag.set(true, defaults: defaults)
        #expect(RestoreInProgressFlag.isSet(defaults: defaults) == true)
    }

    @Test("set to false removes the entry so a later absence is indistinguishable")
    func testSetFalseClears() {
        let defaults = freshDefaults()
        RestoreInProgressFlag.set(true, defaults: defaults)
        RestoreInProgressFlag.set(false, defaults: defaults)
        #expect(RestoreInProgressFlag.isSet(defaults: defaults) == false)
        // Underlying key should be gone (nil), not just `false`.
        #expect(defaults.object(forKey: RestoreInProgressFlag.userDefaultsKey) == nil)
    }
}
