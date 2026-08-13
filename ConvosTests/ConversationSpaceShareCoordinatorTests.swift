@testable import Convos
import ConvosCore
import XCTest

@MainActor
final class ConversationSpaceShareCoordinatorTests: XCTestCase {
    func testSecondShareIsIgnoredWhileFirstIsBusy() async {
        var callCount = 0
        let coordinator = ConversationSpaceShareCoordinator(
            shareOperation: { conversationId, _ in
                callCount += 1
                try await Task.sleep(for: .milliseconds(50))
                return Self.link(conversationId: conversationId)
            },
            copyToClipboard: { _ in }
        )

        let firstShare = Task {
            await coordinator.share(conversationId: "conversation-1", variantId: nil)
        }
        await Task.yield()
        XCTAssertTrue(coordinator.isBusy)

        await coordinator.share(conversationId: "conversation-1", variantId: nil)
        await firstShare.value

        XCTAssertEqual(callCount, 1)
        XCTAssertFalse(coordinator.isBusy)
    }

    func testSuccessCopiesTheMessageVerbatimAndConfirms() async {
        var copied: [String] = []
        let coordinator = ConversationSpaceShareCoordinator(
            shareOperation: { conversationId, _ in
                Self.link(conversationId: conversationId)
            },
            copyToClipboard: { copied.append($0) }
        )

        await coordinator.share(conversationId: "conversation-1", variantId: "pr-1234")

        XCTAssertFalse(coordinator.isBusy)
        XCTAssertEqual(copied, [Self.message])
        XCTAssertEqual(coordinator.alert?.title, "Copied to clipboard")
        // The credential-bearing message stays on the clipboard, never in
        // the alert the user reads.
        XCTAssertEqual(coordinator.alert?.message.contains(Self.message), false)
    }

    func testTypedErrorsBuildTheirAlertsWithoutCopying() async {
        let cases: [(ConvosAPI.SpaceShareError, String)] = [
            (.invalidRequest, "Invalid conversation"),
            (.spaceNotFound, "No Space found"),
            (.repositoryUnavailable, "Repository unavailable"),
            (.variantUnavailable, "Variant unavailable"),
            (.unavailable, "Sharing unavailable"),
            (.timeout, "Request timed out"),
            (.failed, "Couldn't create a share link"),
            (.rateLimited, "Too many share links")
        ]

        for (error, expectedTitle) in cases {
            var copied: [String] = []
            let coordinator = ConversationSpaceShareCoordinator(
                shareOperation: { _, _ in throw error },
                copyToClipboard: { copied.append($0) }
            )

            await coordinator.share(conversationId: "conversation-1", variantId: nil)

            XCTAssertEqual(coordinator.alert?.title, expectedTitle)
            XCTAssertTrue(copied.isEmpty)
        }
    }

    func testURLTimeoutMapsToTheTimeoutAlert() async {
        let coordinator = ConversationSpaceShareCoordinator(
            shareOperation: { _, _ in throw URLError(.timedOut) },
            copyToClipboard: { _ in XCTFail("Nothing should be copied on timeout") }
        )

        await coordinator.share(conversationId: "conversation-1", variantId: nil)

        XCTAssertEqual(coordinator.alert?.title, "Request timed out")
    }

    func testUnexpectedErrorFallsBackToTheGenericAlert() async {
        let coordinator = ConversationSpaceShareCoordinator(
            shareOperation: { _, _ in throw URLError(.notConnectedToInternet) },
            copyToClipboard: { _ in XCTFail("Nothing should be copied on failure") }
        )

        await coordinator.share(conversationId: "conversation-1", variantId: nil)

        XCTAssertEqual(coordinator.alert?.title, "Couldn't create a share link")
    }

    private static let message =
        "Import this space using the space-import skill:\nhttps://user:secret@code.storage/xmtp/repo.git"

    private static func link(conversationId: String) -> ConvosAPI.SpaceShareLink {
        .init(
            conversationId: conversationId,
            message: message,
            expiresAt: "2026-08-20T12:00:00.000Z"
        )
    }
}
