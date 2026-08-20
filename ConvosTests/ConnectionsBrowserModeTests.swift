@testable import Convos
import ConvosCore
import XCTest

final class ConnectionsBrowserModeTests: XCTestCase {
    func testAppSettingsModeRendersWithoutDismissChrome() {
        let mode: ConnectionsBrowserMode = .appSettings
        XCTAssertFalse(mode.showsDismissChrome)
        XCTAssertNil(mode.conversationId)
        XCTAssertNil(mode.agentInboxId)
        XCTAssertNil(mode.agentDisplayName)
    }

    func testComposerModalModeRendersWithDismissChrome() {
        let mode: ConnectionsBrowserMode = .composerModal(
            conversationId: "dm-1",
            agentInboxId: "agent-1",
            agentDisplayName: "Caley"
        )
        XCTAssertTrue(mode.showsDismissChrome)
        XCTAssertEqual(mode.conversationId, "dm-1")
        XCTAssertEqual(mode.agentInboxId, "agent-1")
        XCTAssertEqual(mode.agentDisplayName, "Caley")
    }

    /// The chat-scoped copy is fixed: it names no agent, so a name that has
    /// not resolved (or has just changed) cannot move it. The account-level
    /// one keeps its own copy byte for byte.
    func testHeaderSubtitleIsConstantInTheModalWhateverTheAgentIsCalled() {
        for name in ["Caley", "", "   "] {
            let mode: ConnectionsBrowserMode = .composerModal(
                conversationId: "dm-1",
                agentInboxId: "agent-1",
                agentDisplayName: name
            )
            XCTAssertEqual(mode.headerSubtitle, "Choose your agent's capabilities in this convo")
        }
        XCTAssertEqual(ConnectionsBrowserMode.appSettings.headerSubtitle, "Give agents new powers in your convos")
    }

    /// The app-wide entitlement status is the account list's business; the
    /// chat-scoped browser withholds the tag and lets the toggle and the
    /// detail push carry the row.
    func testOnlyTheAccountLevelListShowsTheConnectedStatusTag() {
        let modal: ConnectionsBrowserMode = .composerModal(
            conversationId: "dm-1",
            agentInboxId: "agent-1",
            agentDisplayName: "Caley"
        )
        XCTAssertTrue(ConnectionsBrowserMode.appSettings.showsConnectedStatusTag)
        XCTAssertFalse(modal.showsConnectedStatusTag)
    }

    func testModeIdentitiesAreDistinct() {
        let settings: ConnectionsBrowserMode = .appSettings
        let modal: ConnectionsBrowserMode = .composerModal(
            conversationId: "dm-1",
            agentInboxId: "agent-1",
            agentDisplayName: "Caley"
        )
        let otherModal: ConnectionsBrowserMode = .composerModal(
            conversationId: "dm-2",
            agentInboxId: "agent-1",
            agentDisplayName: "Caley"
        )
        XCTAssertNotEqual(settings.id, modal.id)
        XCTAssertNotEqual(modal.id, otherModal.id)
    }

    /// The modal presents via `fullScreenCover(item:)`, so identity change
    /// tears it down and re-presents it. An agent renaming mid-session must
    /// not do that.
    func testRenamingTheAgentLeavesTheModalIdentityUnchanged() {
        let before: ConnectionsBrowserMode = .composerModal(
            conversationId: "dm-1",
            agentInboxId: "agent-1",
            agentDisplayName: "Caley"
        )
        let after: ConnectionsBrowserMode = .composerModal(
            conversationId: "dm-1",
            agentInboxId: "agent-1",
            agentDisplayName: "Caley the Second"
        )
        XCTAssertEqual(before.id, after.id)
        XCTAssertNotEqual(before, after, "the value still carries the new name")
    }
}
