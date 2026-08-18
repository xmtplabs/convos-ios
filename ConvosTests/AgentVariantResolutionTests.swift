@testable import Convos
import ConvosCore
import XCTest

/// The one resolution every agent call reads -- the join, the join-status poll,
/// and the participation read and mirror -- for which agent variant it routes
/// to. No environment pins a variant, so that answer comes from the dev
/// selector, and is the backend's default worker without it.
@MainActor
final class AgentVariantResolutionTests: XCTestCase {
    private var previousSelection: ConvosAPI.AgentVariant?
    private var previousSelectorEnabled: Bool = false

    override func setUp() async throws {
        try await super.setUp()
        previousSelection = FeatureFlags.shared.selectedAgentVariant
        previousSelectorEnabled = FeatureFlags.shared.isAgentVariantSelectorEnabled
    }

    override func tearDown() async throws {
        // The flag goes back first: turning the selector off clears whatever
        // selection is stored, which would undo the restore below.
        FeatureFlags.shared.isAgentVariantSelectorEnabled = previousSelectorEnabled
        FeatureFlags.shared.selectedAgentVariant = previousSelection
        try await super.tearDown()
    }

    /// A config pin would send every agent join in the environment to one
    /// ephemeral worker, dev selector or not. Builds ship unpinned and let the
    /// backend pick the default; pinning is a deliberate, temporary edit to the
    /// config file, not a state to drift into.
    func testNoEnvironmentPinsAVariant() {
        XCTAssertNil(
            ConfigManager.shared.pinnedAgentVariantSlug,
            "the build ships unpinned; agent calls route to the default worker"
        )
    }

    /// With nothing pinned, a developer's selection is what reaches the wire.
    func testSelectorPickRoutesEveryAgentCall() {
        FeatureFlags.shared.isAgentVariantSelectorEnabled = true
        FeatureFlags.shared.selectedAgentVariant = variant(slug: "some-variant")

        XCTAssertEqual(FeatureFlags.shared.effectiveAgentVariantSlug, "some-variant")
    }

    /// The selector flag gates the read, so a selection left behind on disk
    /// can't keep routing joins once the dev toggle is off.
    func testSelectorOffRoutesToTheDefaultWorker() {
        FeatureFlags.shared.isAgentVariantSelectorEnabled = false
        FeatureFlags.shared.selectedAgentVariant = variant(slug: "some-variant")

        XCTAssertNil(FeatureFlags.shared.effectiveAgentVariantSlug)
    }

    private func variant(slug: String) -> ConvosAPI.AgentVariant {
        ConvosAPI.AgentVariant(
            slug: slug,
            label: slug,
            whatToTest: "",
            status: "ready"
        )
    }
}
