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
    func testSpacePullRequestProposalDefaultsOffPersistsAndNotifiesObservers() {
        let key = "featureFlags.spacePullRequestProposalEnabled"
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

        let flags = FeatureFlags.shared
        XCTAssertFalse(flags.isSpacePullRequestProposalEnabled)

        let changed = expectation(description: "Space pull request proposal flag observation fired")
        withObservationTracking {
            _ = flags.isSpacePullRequestProposalEnabled
        } onChange: {
            changed.fulfill()
        }

        flags.isSpacePullRequestProposalEnabled = true
        wait(for: [changed], timeout: 1.0)
        XCTAssertTrue(defaults.bool(forKey: key))
        XCTAssertTrue(flags.isSpacePullRequestProposalEnabled)
    }

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

    func testTogglingNewComposerNotifiesObservers() {
        let flags = FeatureFlags.shared
        let initial = flags.isNewComposerEnabled
        defer { flags.isNewComposerEnabled = initial }

        let changed = expectation(description: "new composer flag observation fired")
        withObservationTracking {
            _ = flags.isNewComposerEnabled
        } onChange: {
            changed.fulfill()
        }

        flags.isNewComposerEnabled = !initial
        wait(for: [changed], timeout: 1.0)
        XCTAssertEqual(flags.isNewComposerEnabled, !initial)
    }

    func testTogglingDesktopModeNotifiesObservers() {
        let flags = FeatureFlags.shared
        let initial = flags.isDesktopModeEnabled
        defer { flags.isDesktopModeEnabled = initial }

        let changed = expectation(description: "desktop mode flag observation fired")
        withObservationTracking {
            _ = flags.isDesktopModeEnabled
        } onChange: {
            changed.fulfill()
        }

        flags.isDesktopModeEnabled = !initial
        wait(for: [changed], timeout: 1.0)
        XCTAssertEqual(flags.isDesktopModeEnabled, !initial)
    }

    func testTogglingAgentAutoJoinNotifiesObservers() {
        let flags = FeatureFlags.shared
        let initial = flags.isAgentAutoJoinEnabled
        defer { flags.isAgentAutoJoinEnabled = initial }

        let changed = expectation(description: "agent auto-join flag observation fired")
        withObservationTracking {
            _ = flags.isAgentAutoJoinEnabled
        } onChange: {
            changed.fulfill()
        }

        flags.isAgentAutoJoinEnabled = !initial
        wait(for: [changed], timeout: 1.0)
        XCTAssertEqual(flags.isAgentAutoJoinEnabled, !initial)
    }

    func testDesktopModeActivatesNewComposer() {
        let flags = FeatureFlags.shared
        let initialDesktop = flags.isDesktopModeEnabled
        let initialComposer = flags.isNewComposerEnabled
        defer {
            flags.isDesktopModeEnabled = initialDesktop
            flags.isNewComposerEnabled = initialComposer
        }

        flags.isNewComposerEnabled = false
        flags.isDesktopModeEnabled = true
        XCTAssertTrue(flags.isNewComposerActive)

        flags.isDesktopModeEnabled = false
        XCTAssertFalse(flags.isNewComposerActive)

        flags.isNewComposerEnabled = true
        XCTAssertTrue(flags.isNewComposerActive)
    }
}
