@testable import Convos
import Observation
import XCTest

/// The prod debug menu flag is a computed property over UserDefaults, so the
/// accessor registers with the observation registrar by hand (same pattern as
/// `FeatureFlags`, pinned by `FeatureFlagsObservationTests`). These tests pin
/// that wiring: the App Settings "Debug menu" row and the "Debug mode" toggle
/// inside the menu read the flag in their bodies and must be invalidated the
/// moment it is toggled from either place. They also pin the persistence key,
/// which existing devices already carry.
@MainActor
final class DebugMenuFlagStoreObservationTests: XCTestCase {
    private let key = "convos.debugMenu.enabled.v1"

    func testDefaultsOffPersistsUnderStableKeyAndNotifiesObservers() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: key)

        let store = DebugMenuFlagStore.shared
        XCTAssertFalse(store.isEnabled)

        let changed = expectation(description: "Debug menu flag observation fired")
        withObservationTracking {
            _ = store.isEnabled
        } onChange: {
            changed.fulfill()
        }

        store.enable()
        wait(for: [changed], timeout: 1.0)
        XCTAssertTrue(defaults.bool(forKey: key))
        XCTAssertTrue(store.isEnabled)
    }

    func testDisablingNotifiesObserversAndRoundTrips() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let store = DebugMenuFlagStore.shared
        store.isEnabled = true
        XCTAssertTrue(store.isEnabled)

        let changed = expectation(description: "Debug menu flag disable observation fired")
        withObservationTracking {
            _ = store.isEnabled
        } onChange: {
            changed.fulfill()
        }

        store.isEnabled = false
        wait(for: [changed], timeout: 1.0)
        XCTAssertFalse(defaults.bool(forKey: key))
        XCTAssertFalse(store.isEnabled)
    }
}
