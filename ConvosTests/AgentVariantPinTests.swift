@testable import Convos
import ConvosCore
import XCTest

/// The agent variant every agent call routes to is pinned in config.json, and
/// the value is a registry slug the backend expands to
/// `ephemeral-<slug>.convos.fun`. These cover the plumbing from that file
/// through `ConfigManager` to the single resolution the call sites read.
@MainActor
final class AgentVariantPinTests: XCTestCase {
    func testBuildPinsTheSpacesVariant() {
        XCTAssertEqual(
            ConfigManager.shared.pinnedAgentVariantSlug,
            "spaces",
            "non-production builds pin the spaces variant, matching Android"
        )
    }

    func testEffectiveSlugIsThePin() {
        XCTAssertEqual(FeatureFlags.shared.effectiveAgentVariantSlug, "spaces")
    }

    /// The pin wins outright: a build that pins a variant routes every agent
    /// call there regardless of what the dev selector holds.
    func testPinWinsOverTheSelector() {
        let previousSelection = FeatureFlags.shared.selectedAgentVariant
        let previousEnabled = FeatureFlags.shared.isAgentVariantSelectorEnabled
        defer {
            FeatureFlags.shared.selectedAgentVariant = previousSelection
            FeatureFlags.shared.isAgentVariantSelectorEnabled = previousEnabled
        }

        FeatureFlags.shared.isAgentVariantSelectorEnabled = true
        FeatureFlags.shared.selectedAgentVariant = ConvosAPI.AgentVariant(
            slug: "something-else",
            label: "Something else",
            whatToTest: "",
            status: "ready"
        )

        XCTAssertEqual(FeatureFlags.shared.effectiveAgentVariantSlug, "spaces")
    }

    /// The slug is what goes on the wire, not the worker host: the backend
    /// derives `ephemeral-spaces.convos.fun` from it, and pinning the host
    /// instead misses the registry lookup and silently falls back.
    func testPinIsASlugNotAWorkerHost() {
        let slug = ConfigManager.shared.pinnedAgentVariantSlug
        XCTAssertFalse(slug?.hasPrefix("ephemeral-") ?? false)
        XCTAssertFalse(slug?.contains(".") ?? false)
    }
}
