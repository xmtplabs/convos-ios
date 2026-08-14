import ConvosCore
import ConvosInvites
import XCTest
@testable import Convos

/// Coverage for the `.scannedCode` latch lifecycle. The latch is set at
/// scan-recognition time so a mid-join dismiss cannot cancel the in-flight
/// join or discard the conversation it lands in - that part must not
/// change. But a recognized-then-conclusively-failed join (expired invite,
/// spawn error with no retry) has nothing left to protect: the latch must
/// be released so the error-sheet dismiss discards the untouched
/// conversation instead of stranding a visible empty row.
@MainActor
final class NewConversationViewModelScanLatchTests: XCTestCase {
    func testDefinitiveJoinFailureReleasesScanLatchAndDismissDiscards() async {
        let fixtures = makeFixtures()
        await adoptClaimedConversation(fixtures)
        await recognizeScan(fixtures)

        fixtures.stateManager.setState(
            .joinFailed(inviteTag: "tag", error: Self.definitiveJoinError)
        )
        await waitFor { !fixtures.viewModel.engagement.contains(.scannedCode) }

        XCTAssertFalse(fixtures.viewModel.engagement.contains(.scannedCode),
                       "A conclusively dead join must release the scan keep-latch")
        XCTAssertNotNil(fixtures.viewModel.displayError)
        XCTAssertNil(fixtures.viewModel.displayError?.retryAction,
                     "An expired invite is terminal - no retry is offered")

        fixtures.viewModel.dismissWithDeletion()
        await waitFor { fixtures.session.discardedConversationIds.contains(Constant.claimedId) }

        XCTAssertEqual(fixtures.session.discardedConversationIds, [Constant.claimedId],
                       "Dismissing the failure must delete the untouched claimed conversation")
    }

    func testRetryableFailureKeepsScanLatch() async {
        let fixtures = makeFixtures()
        await adoptClaimedConversation(fixtures)
        await recognizeScan(fixtures)

        fixtures.stateManager.setState(.error(ConversationStateMachineError.timedOut))
        await waitFor { fixtures.viewModel.displayError != nil }

        XCTAssertNotNil(fixtures.viewModel.displayError?.retryAction,
                        "A timeout offers a retry")
        XCTAssertTrue(fixtures.viewModel.engagement.contains(.scannedCode),
                      "A retryable failure must keep the latch protecting the relaunched join")
    }

    func testSuccessfulScanJoinKeepsLatchAndJoinedConversation() async {
        let fixtures = makeFixtures()
        await adoptClaimedConversation(fixtures)
        await recognizeScan(fixtures)

        fixtures.stateManager.setState(
            .ready(ConversationReadyResult(conversationId: Constant.joinedId, origin: .joined))
        )
        await waitFor { fixtures.viewModel.claimedConversationId == nil }

        XCTAssertTrue(fixtures.viewModel.engagement.contains(.scannedCode),
                      "A successful join keeps the latch")

        fixtures.viewModel.dismissWithDeletion()
        // The superseded claim goes through the engagement gate; the joined
        // conversation itself is never discarded.
        await waitFor { !fixtures.session.discardedIfUnengagedConversationIds.isEmpty }
        XCTAssertEqual(fixtures.session.discardedIfUnengagedConversationIds, [Constant.claimedId])
        XCTAssertFalse(fixtures.session.discardedIfUnengagedConversationIds.contains(Constant.joinedId),
                       "The joined conversation must be kept on dismiss")
        XCTAssertTrue(fixtures.session.discardedConversationIds.isEmpty)
    }

    func testMidJoinDismissStaysProtected() async {
        let fixtures = makeFixtures()
        await adoptClaimedConversation(fixtures)
        await recognizeScan(fixtures)

        // No failure state: the join is still in flight when the sheet is
        // dismissed. The latch must survive, and the conversation the join is
        // landing in must be left alone. The claimed row is not that
        // conversation - the join lands somewhere else and supersedes it - so
        // dismissing does delete the claimed row it abandoned.
        fixtures.viewModel.dismissWithDeletion()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(fixtures.viewModel.engagement.contains(.scannedCode),
                      "A mid-join dismiss must not clear the latch")
        XCTAssertFalse(fixtures.session.discardedConversationIds.contains(Constant.joinedId),
                       "A mid-join dismiss must never touch the conversation being joined")
        XCTAssertFalse(fixtures.session.discardedIfUnengagedConversationIds.contains(Constant.joinedId),
                       "A mid-join dismiss must never touch the conversation being joined")
    }

    // MARK: - Helpers

    private struct Fixtures {
        let viewModel: NewConversationViewModel
        let stateManager: MockConversationStateManager
        let session: MockInboxesService
    }

    private func makeFixtures() -> Fixtures {
        // The default mock draft conversation carries other members, which
        // would latch `.memberJoined` and mask the `.scannedCode` behavior
        // under test; an untouched embedded convo is memberless.
        let stateManager = MockConversationStateManager(
            conversationId: Constant.stateManagerId,
            draftConversationRepository: MockDraftConversationRepository(
                conversation: .empty(id: Constant.stateManagerId)
            )
        )
        stateManager.autoCompletesActions = false
        let messagingService = MockMessagingService(conversationStateManager: stateManager)
        let session = MockInboxesService(mockMessagingService: messagingService)
        let viewModel = NewConversationViewModel(
            session: session,
            messagingService: messagingService,
            existingConversationId: Constant.claimedId
        )
        return Fixtures(viewModel: viewModel, stateManager: stateManager, session: session)
    }

    /// Warm-cache shape: the flow claimed a pooled conversation before the
    /// composer opened, and the state machine resumes that same conversation
    /// through `useExisting` rather than publishing a second one.
    private func adoptClaimedConversation(_ fixtures: Fixtures) async {
        fixtures.stateManager.setState(
            .ready(ConversationReadyResult(conversationId: Constant.claimedId, origin: .existing))
        )
        await waitFor { fixtures.viewModel.claimedConversationId == Constant.claimedId }
        XCTAssertEqual(fixtures.viewModel.claimedConversationId, Constant.claimedId)
    }

    /// Scans a recognizable invite URL: latches `.scannedCode` and starts a
    /// join that the mock holds in flight (`autoCompletesActions == false`).
    private func recognizeScan(_ fixtures: Fixtures) async {
        let inviteURL = "https://\(ConfigManager.shared.associatedDomain)/i/abc123def456"
        fixtures.viewModel.handleScannedCode(inviteURL)
        XCTAssertTrue(fixtures.viewModel.engagement.contains(.scannedCode),
                      "A recognized scan must latch at recognition time")
        await waitFor {
            if case .validating = fixtures.viewModel.conversationState { return true }
            return false
        }
    }

    /// Polls until the condition holds, yielding the main actor between
    /// checks so state-stream handlers and discard tasks can run.
    private func waitFor(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static let definitiveJoinError: InviteJoinError = InviteJoinError(
        errorType: .conversationExpired,
        inviteTag: "tag",
        timestamp: Date()
    )

    private enum Constant {
        static let stateManagerId: String = "scan-latch-convo"
        static let claimedId: String = "scan-latch-claimed"
        static let joinedId: String = "scan-latch-joined"
    }
}
