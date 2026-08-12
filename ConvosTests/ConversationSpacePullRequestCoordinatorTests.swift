@testable import Convos
import ConvosCore
import XCTest

@MainActor
final class ConversationSpacePullRequestCoordinatorTests: XCTestCase {
    func testSecondProposalIsIgnoredWhileFirstIsBusy() async {
        var callCount = 0
        let coordinator = ConversationSpacePullRequestCoordinator { conversationId, _ in
            callCount += 1
            try await Task.sleep(for: .milliseconds(50))
            return Self.unchanged(conversationId: conversationId)
        }

        let firstProposal = Task {
            await coordinator.propose(conversationId: "conversation-1", variantId: nil)
        }
        await Task.yield()
        XCTAssertTrue(coordinator.isBusy)

        await coordinator.propose(conversationId: "conversation-1", variantId: nil)
        await firstProposal.value

        XCTAssertEqual(callCount, 1)
        XCTAssertFalse(coordinator.isBusy)
    }

    func testPullRequestOutcomeClearsBusyAndBuildsOpenAlert() async throws {
        let prURL = try XCTUnwrap(URL(string: "https://github.com/xmtplabs/convos-assistants/pull/123"))
        let coordinator = ConversationSpacePullRequestCoordinator { conversationId, _ in
            .pullRequest(try .init(
                conversationId: conversationId,
                prURL: prURL,
                prNumber: 123,
                branch: "space-upstream/conversation-1",
                commitSha: "commit-1",
                forkCommitSha: "fork-1",
                wrote: 1,
                deleted: 0,
                refusedCount: 0
            ))
        }

        await coordinator.propose(conversationId: "conversation-1", variantId: "pr-1234")

        XCTAssertFalse(coordinator.isBusy)
        XCTAssertEqual(coordinator.alert?.title, "Pull request proposed")
        XCTAssertEqual(coordinator.alert?.pullRequestURL, prURL)
    }

    func testUnchangedOutcomeClearsBusyAndBuildsMatchingAlert() async {
        let coordinator = ConversationSpacePullRequestCoordinator { conversationId, _ in
            Self.unchanged(conversationId: conversationId)
        }

        await coordinator.propose(conversationId: "conversation-1", variantId: nil)

        XCTAssertFalse(coordinator.isBusy)
        XCTAssertEqual(coordinator.alert?.title, "Already matches the starter")
        XCTAssertNil(coordinator.alert?.pullRequestURL)
    }

    func testTypedFailureClearsBusyAndBuildsGuidanceAlert() async {
        let coordinator = ConversationSpacePullRequestCoordinator { _, _ in
            throw ConvosAPI.SpacePullRequestProposalError.notArmed
        }

        await coordinator.propose(conversationId: "conversation-1", variantId: nil)

        XCTAssertFalse(coordinator.isBusy)
        XCTAssertEqual(coordinator.alert?.title, "Deployment not armed")
        XCTAssertEqual(
            coordinator.alert?.message,
            "The selected deployment is not configured to propose Space pull requests."
        )
    }

    func testTimeoutUsesUncertaintyAndSafeRetryCopy() async {
        let coordinator = ConversationSpacePullRequestCoordinator { _, _ in
            throw ConvosAPI.SpacePullRequestProposalError.timeout
        }

        await coordinator.propose(conversationId: "conversation-1", variantId: nil)

        XCTAssertFalse(coordinator.isBusy)
        XCTAssertEqual(
            coordinator.alert?.message,
            "The request timed out. The PR may still have been updated; it is safe to try again."
        )
    }

    func testProposalPassesRouteIdentifiers() async {
        var receivedConversationId: String?
        var receivedVariantId: String?
        let coordinator = ConversationSpacePullRequestCoordinator { conversationId, variantId in
            receivedConversationId = conversationId
            receivedVariantId = variantId
            return Self.unchanged(conversationId: conversationId)
        }

        await coordinator.propose(conversationId: "conversation-1", variantId: "pr-1234")

        XCTAssertEqual(receivedConversationId, "conversation-1")
        XCTAssertEqual(receivedVariantId, "pr-1234")
    }

    private static func unchanged(conversationId: String) -> ConvosAPI.SpacePullRequestProposalOutcome {
        .unchanged(.init(
            conversationId: conversationId,
            forkCommitSha: "fork-1",
            wrote: 0,
            deleted: 0,
            refusedCount: 0
        ))
    }
}
