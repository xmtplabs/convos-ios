@testable import Convos
import Observation
import XCTest

/// The feature flags are computed properties over UserDefaults, so each
/// accessor registers with the observation registrar by hand. These tests
/// pin that wiring: a view that reads a flag in its body must be
/// invalidated the moment the flag is toggled. The debug menu's dependent
/// rows (for example the abilities sub-toggles) rely on this to appear
/// without leaving and re-entering the screen.
@MainActor
final class FeatureFlagsObservationTests: XCTestCase {
    func testTogglingAbilitiesV2NotifiesObservers() {
        let flags = FeatureFlags.shared
        let initial = flags.isAbilitiesV2Enabled
        defer { flags.isAbilitiesV2Enabled = initial }

        let changed = expectation(description: "abilities flag observation fired")
        withObservationTracking {
            _ = flags.isAbilitiesV2Enabled
        } onChange: {
            changed.fulfill()
        }

        flags.isAbilitiesV2Enabled = !initial
        wait(for: [changed], timeout: 1.0)
        XCTAssertEqual(flags.isAbilitiesV2Enabled, !initial)
    }

    func testTogglingBidiStreamsNotifiesObservers() {
        let flags = FeatureFlags.shared
        let initial = flags.isXMTPBidiStreamsEnabled
        defer { flags.isXMTPBidiStreamsEnabled = initial }

        let changed = expectation(description: "bidi flag observation fired")
        withObservationTracking {
            _ = flags.isXMTPBidiStreamsEnabled
        } onChange: {
            changed.fulfill()
        }

        flags.isXMTPBidiStreamsEnabled = !initial
        wait(for: [changed], timeout: 1.0)
        XCTAssertEqual(flags.isXMTPBidiStreamsEnabled, !initial)
    }
}
