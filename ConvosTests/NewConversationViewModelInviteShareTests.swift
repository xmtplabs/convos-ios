import ConvosCore
import XCTest
@testable import Convos

/// Coverage for the persisted shared-invite engagement signal. The
/// `.sharedInvite` latch lives only on the view model, but two discard
/// layers are database-gated and cannot see it: the superseded-claim
/// discard when a later scan joins a different conversation, and the state
/// machine's previous-conversation cleanup during that join. Sharing must
/// therefore also persist `ConversationLocalState.hasSharedInvite`, which
/// `ConversationEngagement.isEngaged` reads.
@MainActor
final class NewConversationViewModelInviteShareTests: XCTestCase {
    func testMarkInviteSharedPersistsHasSharedInvite() async {
        let fixtures = makeFixtures()

        fixtures.viewModel.markInviteShared()

        await waitFor { fixtures.localStateWriter.hasSharedInviteStates[fixtures.stateManager.conversationId] == true }
        XCTAssertEqual(
            fixtures.localStateWriter.hasSharedInviteStates[fixtures.stateManager.conversationId],
            true,
            "Sharing the invite must persist the set-once hasSharedInvite marker"
        )
        XCTAssertTrue(
            fixtures.viewModel.engagement.contains(.sharedInvite),
            "The synchronous VM latch must stay alongside the persisted marker"
        )
    }

    func testMarkInviteSharedPersistsForTheClaimedConversation() async {
        let fixtures = makeFixtures()

        // Embedded auto-create: the state machine published a visible group
        // and the VM adopts its id as the claimed row at `.ready`.
        fixtures.stateManager.setState(
            .ready(ConversationReadyResult(conversationId: Constant.claimedId, origin: .created))
        )
        await waitFor { fixtures.viewModel.claimedConversationId == Constant.claimedId }

        fixtures.viewModel.markInviteShared()

        await waitFor { fixtures.localStateWriter.hasSharedInviteStates[Constant.claimedId] == true }
        XCTAssertEqual(
            fixtures.localStateWriter.hasSharedInviteStates[Constant.claimedId],
            true,
            "The persisted marker must key off the claimed conversation, not the draft placeholder"
        )
    }

    func testSupersededScanRoutesSharedConversationThroughEngagementGate() async {
        let fixtures = makeFixtures()

        fixtures.stateManager.setState(
            .ready(ConversationReadyResult(conversationId: Constant.claimedId, origin: .created))
        )
        await waitFor { fixtures.viewModel.claimedConversationId == Constant.claimedId }

        fixtures.viewModel.markInviteShared()
        await waitFor { fixtures.localStateWriter.hasSharedInviteStates[Constant.claimedId] == true }

        // A scanned invite joins a different conversation, superseding the
        // claimed one. The discard must be the engagement-gated shape - the
        // database gate sees the persisted hasSharedInvite and keeps the
        // conversation - never the unconditional delete.
        fixtures.stateManager.setState(
            .ready(ConversationReadyResult(conversationId: Constant.joinedId, origin: .joined))
        )
        await waitFor { fixtures.session.discardedIfUnengagedConversationIds.contains(Constant.claimedId) }

        XCTAssertEqual(fixtures.session.discardedIfUnengagedConversationIds, [Constant.claimedId],
                       "The superseded claim must route through the engagement-gated discard")
        XCTAssertTrue(fixtures.session.discardedConversationIds.isEmpty,
                      "The unconditional discard must never run for a superseded claim")
        XCTAssertNil(fixtures.viewModel.claimedConversationId,
                     "The superseded claim id must be cleared so the joined conversation is kept on dismiss")
    }

    // MARK: - Helpers

    private struct Fixtures {
        let viewModel: NewConversationViewModel
        let stateManager: MockConversationStateManager
        let localStateWriter: MockConversationLocalStateWriter
        let session: MockInboxesService
    }

    private func makeFixtures() -> Fixtures {
        let localStateWriter = MockConversationLocalStateWriter()
        // Memberless draft conversation, matching an untouched embedded
        // convo (the default mock draft carries other members).
        let stateManager = MockConversationStateManager(
            conversationId: Constant.stateManagerId,
            draftConversationRepository: MockDraftConversationRepository(
                conversation: .empty(id: Constant.stateManagerId)
            ),
            conversationLocalStateWriter: localStateWriter
        )
        let messagingService = MockMessagingService(conversationStateManager: stateManager)
        let session = MockInboxesService(mockMessagingService: messagingService)
        let viewModel = NewConversationViewModel(
            session: session,
            messagingService: messagingService,
            showsEmbeddedInvite: true
        )
        return Fixtures(
            viewModel: viewModel,
            stateManager: stateManager,
            localStateWriter: localStateWriter,
            session: session
        )
    }

    /// Polls until the condition holds, yielding the main actor between
    /// checks so state-stream handlers and persist tasks can run.
    private func waitFor(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private enum Constant {
        static let stateManagerId: String = "share-test-convo"
        static let claimedId: String = "share-test-claimed"
        static let joinedId: String = "share-test-joined"
    }
}
