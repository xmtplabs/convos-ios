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

    /// A prepared conversation goes back in the pool when its flow is
    /// abandoned. If the pick it carried survived there, the next compose
    /// would adopt that conversation and build its agent under the old
    /// variant — so "No variant" has to clear the binding, not skip it.
    func testANilPickClearsAnAbandonedFlowsBinding() {
        let prepared = "prepared-conversation"
        AgentVariantAssignmentStore.shared.assign(slug: "left-behind", to: prepared)
        defer { AgentVariantAssignmentStore.shared.assign(slug: nil, to: prepared) }

        AgentVariantAssignmentStore.shared.assign(slug: nil, to: prepared)

        XCTAssertNil(AgentVariantAssignmentStore.shared.slug(for: prepared))
    }

    /// The same conversation picked again under a different variant takes the
    /// new one; a stale pick never wins by having been written first.
    func testASecondPickReplacesAnAbandonedOne() {
        let prepared = "prepared-conversation-2"
        AgentVariantAssignmentStore.shared.assign(slug: "first-pick", to: prepared)
        defer { AgentVariantAssignmentStore.shared.assign(slug: nil, to: prepared) }

        AgentVariantAssignmentStore.shared.assign(slug: "second-pick", to: prepared)

        XCTAssertEqual(AgentVariantAssignmentStore.shared.slug(for: prepared), "second-pick")
    }

    func testDocModeChoosesNewestExactLabelMatchFromRegistryOrder() throws {
        let newestDoc = variant(slug: "doc-newest", label: "Doc")
        let variants = [
            variant(slug: "other", label: "Other"),
            newestDoc,
            variant(slug: "doc-older", label: "Doc"),
            variant(slug: "wrong-case", label: "doc"),
        ]

        let resolved = AgentVariantRegistry.mostRecentlyRegisteredVariant(
            labeled: "Doc",
            in: variants
        )

        XCTAssertEqual(try XCTUnwrap(resolved), newestDoc)
    }

    func testDocModeReportsNoVariantWhenRegistryHasNoExactLabelMatch() {
        let resolved = AgentVariantRegistry.mostRecentlyRegisteredVariant(
            labeled: "Doc",
            in: [variant(slug: "wrong-case", label: "doc")]
        )

        XCTAssertNil(resolved)
    }

    func testDocModeResolutionFailuresBlockEnablementWithRecoveryCopy() {
        XCTAssertNotNil(DocModeResolutionPolicy.enablementError(for: .notRegistered))
        XCTAssertNotNil(DocModeResolutionPolicy.enablementError(for: .unavailable))
        XCTAssertNil(DocModeResolutionPolicy.enablementError(
            for: .resolved(variant(slug: "doc", label: "Doc"))
        ))
    }

    func testDocCapableBuildDefersCacheTimeDefaultAgentBeforeDocModeIsEnabled() {
        XCTAssertTrue(DefaultAgentCacheProvisionPolicy.shouldDefer(
            isDocExperienceEnabled: false,
            isDocExperienceAvailable: true,
            isAgentVariantSelectorEnabled: false
        ))
        XCTAssertTrue(DefaultAgentCacheProvisionPolicy.shouldDefer(
            isDocExperienceEnabled: true,
            isDocExperienceAvailable: false,
            isAgentVariantSelectorEnabled: false
        ))
    }

    func testNonDocBuildCanWarmDefaultAgentWithoutASelector() {
        XCTAssertFalse(DefaultAgentCacheProvisionPolicy.shouldDefer(
            isDocExperienceEnabled: false,
            isDocExperienceAvailable: false,
            isAgentVariantSelectorEnabled: false
        ))
        XCTAssertTrue(DefaultAgentCacheProvisionPolicy.shouldDefer(
            isDocExperienceEnabled: false,
            isDocExperienceAvailable: false,
            isAgentVariantSelectorEnabled: true
        ))
    }

    func testDocModeKeepsAgentBoundToExpectedVariant() {
        let diagnostic = AgentJoinDiagnostic(
            conversationId: "conversation-1",
            requestedVariantId: "doc-runtime",
            variant: .init(slug: "doc-runtime", commit: "abc123"),
            variantDropped: nil
        )

        XCTAssertEqual(
            DocAgentConvergenceAction.resolve(
                conversationId: "conversation-1",
                diagnostic: diagnostic,
                expectedVariantSlug: "doc-runtime"
            ),
            .keep
        )
    }

    func testDocModeReplacesAgentWithoutConfirmedExpectedVariant() {
        let defaultDiagnostic = AgentJoinDiagnostic(
            conversationId: "conversation-1",
            requestedVariantId: nil,
            variant: nil,
            variantDropped: nil
        )
        let droppedDiagnostic = AgentJoinDiagnostic(
            conversationId: "conversation-1",
            requestedVariantId: "doc-runtime",
            variant: .init(slug: "doc-runtime", commit: "abc123"),
            variantDropped: "pr-3655"
        )
        let wrongRequestDiagnostic = AgentJoinDiagnostic(
            conversationId: "conversation-1",
            requestedVariantId: "other-runtime",
            variant: .init(slug: "doc-runtime", commit: "abc123"),
            variantDropped: nil
        )
        let unconfirmedDropDiagnostic = AgentJoinDiagnostic(
            conversationId: "conversation-1",
            requestedVariantId: "doc-runtime",
            variant: .init(slug: "doc-runtime", commit: "abc123"),
            variantDropped: nil
        )
        let wrongRuntimeDiagnostic = AgentJoinDiagnostic(
            conversationId: "conversation-1",
            requestedVariantId: "doc-runtime",
            variant: .init(slug: "other-runtime", commit: "abc123"),
            variantDropped: nil
        )

        XCTAssertEqual(
            DocAgentConvergenceAction.resolve(
                conversationId: "conversation-1",
                diagnostic: defaultDiagnostic,
                expectedVariantSlug: "doc-runtime"
            ),
            .replace
        )
        XCTAssertEqual(
            DocAgentConvergenceAction.resolve(
                conversationId: "conversation-1",
                diagnostic: droppedDiagnostic,
                expectedVariantSlug: "doc-runtime"
            ),
            .replace
        )
        XCTAssertEqual(
            DocAgentConvergenceAction.resolve(
                conversationId: "conversation-1",
                diagnostic: wrongRequestDiagnostic,
                expectedVariantSlug: "doc-runtime"
            ),
            .replace
        )
        XCTAssertEqual(
            DocAgentConvergenceAction.resolve(
                conversationId: "conversation-1",
                diagnostic: unconfirmedDropDiagnostic,
                expectedVariantSlug: "doc-runtime"
            ),
            .replace
        )
        XCTAssertEqual(
            DocAgentConvergenceAction.resolve(
                conversationId: "conversation-1",
                diagnostic: wrongRuntimeDiagnostic,
                expectedVariantSlug: "doc-runtime"
            ),
            .replace
        )
        XCTAssertEqual(
            DocAgentConvergenceAction.resolve(
                conversationId: nil,
                diagnostic: nil,
                expectedVariantSlug: "doc-runtime"
            ),
            .create
        )
    }

    func testDocRuntimeWarningSurfacesDroppedOrMissingVariants() {
        let droppedDiagnostic = AgentJoinDiagnostic(
            conversationId: "conversation-1",
            requestedVariantId: "doc-runtime",
            variant: .init(slug: "doc-runtime", commit: "abc123"),
            variantDropped: "pr-3655"
        )
        let missingVariantDiagnostic = AgentJoinDiagnostic(
            conversationId: "conversation-2",
            requestedVariantId: "doc-runtime",
            variant: nil,
            variantDropped: nil
        )
        let wrongRuntimeDiagnostic = AgentJoinDiagnostic(
            conversationId: "conversation-3",
            requestedVariantId: "doc-runtime",
            variant: .init(slug: "other-runtime", commit: "abc123"),
            variantDropped: nil
        )

        XCTAssertEqual(
            DocRuntimeFallbackWarning.resolve(
                isDocModeEnabled: true,
                diagnostic: droppedDiagnostic
            )?.requestedSlug,
            "doc-runtime"
        )
        XCTAssertEqual(
            DocRuntimeFallbackWarning.resolve(
                isDocModeEnabled: true,
                configuredSlug: "doc-runtime",
                diagnostic: .init(
                    conversationId: "conversation-3",
                    requestedVariantId: nil,
                    variant: nil,
                    variantDropped: nil
                )
            )?.requestedSlug,
            "doc-runtime"
        )
        XCTAssertEqual(
            DocRuntimeFallbackWarning.resolve(
                isDocModeEnabled: true,
                diagnostic: missingVariantDiagnostic
            )?.requestedSlug,
            "doc-runtime"
        )
        XCTAssertEqual(
            DocRuntimeFallbackWarning.resolve(
                isDocModeEnabled: true,
                diagnostic: wrongRuntimeDiagnostic
            )?.requestedSlug,
            "doc-runtime"
        )
    }

    func testDocRuntimeWarningStaysHiddenForTheRequestedRuntime() {
        let diagnostic = AgentJoinDiagnostic(
            conversationId: "conversation-1",
            requestedVariantId: "doc-runtime",
            variant: .init(slug: "doc-runtime", commit: "abc123"),
            variantDropped: nil
        )

        XCTAssertNil(DocRuntimeFallbackWarning.resolve(
            isDocModeEnabled: true,
            diagnostic: diagnostic
        ))
        XCTAssertNil(DocRuntimeFallbackWarning.resolve(
            isDocModeEnabled: false,
            diagnostic: diagnostic
        ))
    }

    private func variant(slug: String, label: String? = nil) -> ConvosAPI.AgentVariant {
        ConvosAPI.AgentVariant(
            slug: slug,
            label: label ?? slug,
            whatToTest: "",
            status: "ready"
        )
    }
}
