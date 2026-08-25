import ConvosCore
import ConvosInvites
import ConvosMetrics
import XCTest
@testable import Convos

/// Coverage for the join funnel's reporting invariants.
///
/// Instrumenting the failure paths introduced two ways to over-report that
/// did not exist while those paths were silent: a wait window and a terminal
/// callback can both fire for the same attempt, and `handleErrorState` serves
/// conversation creation as well as joining. Both are pinned here.
@MainActor
final class NewConversationViewModelJoinTelemetryTests: XCTestCase {
    /// A join that produces more than one terminal callback is still one
    /// failed join. Without the latch, `.joinFailed` followed by `.error`
    /// reports two failures for a single attempt.
    func testASecondTerminalCallbackDoesNotReportAgain() async {
        let fixtures = makeFixtures()
        fixtures.viewModel.joinConversation(inviteCode: Constant.inviteCode)

        fixtures.stateManager.setState(
            .joinFailed(inviteTag: "tag", error: Self.expiredJoinError)
        )
        await waitFor { !fixtures.actions.joinOutcomes.isEmpty }

        fixtures.stateManager.setState(.error(ConversationStateMachineError.timedOut))
        await waitFor { fixtures.actions.joinOutcomes.count > 1 }

        XCTAssertEqual(fixtures.actions.joinOutcomes.count, 1,
                       "One attempt reports one failed joined_conversation, not one per callback")
        XCTAssertEqual(fixtures.actions.joinOutcomes.first?.failureReason, .conversationExpired,
                       "The first terminal cause is the one that is reported")
    }

    /// The creator's diagnostic string rides along so a `.genericFailure`
    /// rejection is still diagnosable.
    func testCreatorReasonIsReported() async {
        let fixtures = makeFixtures()
        fixtures.viewModel.joinConversation(inviteCode: Constant.inviteCode)

        fixtures.stateManager.setState(
            .joinFailed(inviteTag: "tag", error: Self.genericJoinError)
        )
        await waitFor { !fixtures.actions.joinOutcomes.isEmpty }

        XCTAssertEqual(fixtures.actions.joinOutcomes.first?.failureReason, .unknown)
        XCTAssertEqual(fixtures.actions.joinOutcomes.first?.creatorReason, "creator private key unavailable")
    }

    /// `handleErrorState` runs for conversation creation too. Only a join
    /// stamps `verificationStartedAt`, and that stamp is what keeps creation
    /// failures out of the join funnel.
    func testCreationFailureIsNotReportedAsAJoin() async {
        let fixtures = makeFixtures()

        fixtures.stateManager.setState(.error(ConversationStateMachineError.timedOut))
        await waitFor { !fixtures.actions.joinOutcomes.isEmpty }

        XCTAssertTrue(fixtures.actions.joinOutcomes.isEmpty,
                      "A failure with no join in flight is not a failed join")
        XCTAssertEqual(fixtures.actions.startCount, 0)
    }

    /// A join that succeeds on a retry must report the attempt it actually
    /// was. `.ready` resets `consecutiveFailureCount` before the join task
    /// reaches `handleJoinSuccess`, so deriving the number at outcome time
    /// reported every successful retry as the first attempt.
    func testSuccessfulRetryReportsItsRealAttemptNumber() async {
        let fixtures = makeFixtures()

        fixtures.viewModel.joinConversation(inviteCode: Constant.inviteCode)
        fixtures.stateManager.setState(
            .joinFailed(inviteTag: "tag", error: Self.expiredJoinError)
        )
        await waitFor { !fixtures.actions.joinOutcomes.isEmpty }
        XCTAssertEqual(fixtures.actions.joinOutcomes.first?.attemptNumber, 1)

        // The mock now carries the retry through to `.ready(origin: .joined)`,
        // which is what resets the failure counter mid-flight.
        fixtures.stateManager.autoCompletesActions = true
        fixtures.viewModel.joinConversation(inviteCode: Constant.inviteCode)
        await waitFor { fixtures.actions.joinOutcomes.contains { $0.isSuccess } }

        let success = fixtures.actions.joinOutcomes.first { $0.isSuccess }
        XCTAssertNotNil(success, "The retry must report a successful join")
        XCTAssertEqual(success?.attemptNumber, 2,
                       "A join that succeeded on the second try reports attempt 2, not 1")
    }

    /// The funnel's denominator counts attempts, not calls into the join path.
    func testJoinAttemptIsReportedOncePerAttempt() async {
        let fixtures = makeFixtures()
        fixtures.viewModel.joinConversation(inviteCode: Constant.inviteCode)
        await waitFor { fixtures.actions.startCount > 0 }

        XCTAssertEqual(fixtures.actions.startCount, 1)
    }

    // MARK: - Fixtures

    private struct Fixtures {
        let viewModel: NewConversationViewModel
        let stateManager: MockConversationStateManager
        let actions: SpyCoreActions
    }

    private func makeFixtures() -> Fixtures {
        let stateManager = MockConversationStateManager(
            conversationId: Constant.stateManagerId,
            draftConversationRepository: MockDraftConversationRepository(
                conversation: .empty(id: Constant.stateManagerId)
            )
        )
        stateManager.autoCompletesActions = false
        let messagingService = MockMessagingService(conversationStateManager: stateManager)
        let session = MockInboxesService(mockMessagingService: messagingService)
        let actions = SpyCoreActions()
        let viewModel = NewConversationViewModel(
            session: session,
            messagingService: messagingService,
            coreActions: actions
        )
        return Fixtures(viewModel: viewModel, stateManager: stateManager, actions: actions)
    }

    private func waitFor(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static let expiredJoinError: InviteJoinError = InviteJoinError(
        errorType: .conversationExpired,
        inviteTag: "tag",
        timestamp: Date()
    )

    private static let genericJoinError: InviteJoinError = InviteJoinError(
        errorType: .genericFailure,
        inviteTag: "tag",
        timestamp: Date(),
        reason: "creator private key unavailable"
    )

    private enum Constant {
        static let stateManagerId: String = "join-telemetry-convo"
        static let inviteCode: String = "abc123def456"
    }
}

/// Records the join funnel calls. `NoOpCoreActions` is `final`, so the whole
/// protocol is restated here; only the join members carry behavior.
private final class SpyCoreActions: CoreActions, @unchecked Sendable {
    struct JoinOutcome {
        let isSuccess: Bool
        let failureReason: JoinFailureReason?
        let creatorReason: String?
        let attemptNumber: Int
    }

    private let lock: NSLock = NSLock()
    private var storedOutcomes: [JoinOutcome] = []
    private var storedStartCount: Int = 0

    var joinOutcomes: [JoinOutcome] {
        lock.withLock { storedOutcomes }
    }

    var startCount: Int {
        lock.withLock { storedStartCount }
    }

    func joinAttemptStarted(source: ConversationSource) async {
        lock.withLock { storedStartCount += 1 }
    }

    // swiftlint:disable:next function_parameter_count
    func joinedConversation(
        verificationDuration: Float,
        memberCount: Int?,
        hasAssistant: Bool?,
        source: ConversationSource,
        isSuccess: Bool,
        failureReason: JoinFailureReason?,
        creatorReason: String?,
        attemptNumber: Int
    ) async {
        lock.withLock {
            storedOutcomes.append(
                JoinOutcome(
                    isSuccess: isSuccess,
                    failureReason: failureReason,
                    creatorReason: creatorReason,
                    attemptNumber: attemptNumber
                )
            )
        }
    }

    func startedConversation() async {}
    func invitedToConversation(memberCount: Int, hasAssistant: Bool, isSuccess: Bool) async {}
    func addedAssistant(memberCount: Int) async {}
    func assistantJoined(
        waitDuration: Float,
        source: AssistantJoinSource,
        memberCount: Int?,
        isSuccess: Bool
    ) async {}
    func assistantJoinRescuedByPolling(streamAgeSecs: Float, pollTick: Int) async {}
    func sentMessage(
        sendingTime: Float,
        memberCount: Int,
        attachmentTypes: [String],
        hasText: Bool,
        hasAssistant: Bool,
        isSuccess: Bool
    ) async {}
    func sharedConversation(
        memberCount: Int,
        hasAssistant: Bool,
        shareTarget: ShareTarget,
        hasExpiration: Bool,
        expiresAfterUse: Bool,
        isSuccess: Bool
    ) async {}
    // swiftlint:disable:next function_parameter_count
    func builtAgent(
        buildDuration: Float,
        instructionCharCount: Int,
        instructionWordCount: Int,
        attachmentTypes: [String],
        hasVoiceMemo: Bool,
        voiceMemoDuration: Float,
        connectionTypes: [String],
        entryMode: AgentBuilderEntryMode,
        isSuccess: Bool,
        fromPromptHint: Bool,
        tapCount: Int
    ) async {}
    func promptHintTapped(tapCount: Int) async {}
    func purchaseInitiated(
        productId: String,
        tier: ConvosMetrics.SubscriptionTier,
        period: ConvosMetrics.SubscriptionPeriod,
        source: ConvosMetrics.PaywallSource
    ) async {}
    func purchaseSucceeded(
        productId: String,
        tier: ConvosMetrics.SubscriptionTier,
        period: ConvosMetrics.SubscriptionPeriod,
        source: ConvosMetrics.PaywallSource,
        durationSecs: Float
    ) async {}
    func purchaseCancelled(productId: String, source: ConvosMetrics.PaywallSource) async {}
    func purchaseFailed(productId: String, source: ConvosMetrics.PaywallSource, reason: PurchaseFailureReason) async {}
    func purchasesRestored(restoredCount: Int) async {}
}
