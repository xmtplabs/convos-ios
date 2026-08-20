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

    /// The compose flow usually settles on a conversation prepared before the
    /// pick was made, which reports `.existing`. Binding only on `.created`
    /// silently dropped the pick on that path, and the agent built on the
    /// default runtime while the picker showed the variant as selected.
    func testAdoptedConversationStillBindsTheVariantPick() {
        XCTAssertTrue(ConversationReadyResult.Origin.created.bindsCreationFlowVariantPick)
        XCTAssertTrue(ConversationReadyResult.Origin.existing.bindsCreationFlowVariantPick)
    }

    /// A joined conversation superseded the one this flow was creating, so the
    /// pick was never made for it.
    func testJoinedConversationDoesNotInheritTheVariantPick() {
        XCTAssertFalse(ConversationReadyResult.Origin.joined.bindsCreationFlowVariantPick)
    }

    /// A conversation's own binding outranks the global selector for every
    /// caller, the warm-cache default-agent provision included — that provision
    /// is the one that reached for the global slug and stranded picked agents
    /// on the default worker.
    func testConversationBindingBeatsTheGlobalSelection() {
        FeatureFlags.shared.isAgentVariantSelectorEnabled = true
        FeatureFlags.shared.selectedAgentVariant = variant(slug: "globally-selected")
        let conversationId = "conversation-under-test"
        AgentVariantAssignmentStore.shared.assign(slug: "picked-at-create", to: conversationId)
        defer { AgentVariantAssignmentStore.shared.assign(slug: nil, to: conversationId) }

        XCTAssertEqual(AgentVariantResolution.slug(for: conversationId), "picked-at-create")
    }

    /// An unbound conversation still follows the selector, so turning the dev
    /// toggle on remains a way to route without going through the picker.
    func testUnboundConversationFallsBackToTheGlobalSelection() {
        FeatureFlags.shared.isAgentVariantSelectorEnabled = true
        FeatureFlags.shared.selectedAgentVariant = variant(slug: "globally-selected")

        XCTAssertEqual(AgentVariantResolution.slug(for: "never-bound"), "globally-selected")
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
