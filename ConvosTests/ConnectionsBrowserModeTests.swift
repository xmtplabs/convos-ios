@testable import Convos
import ConvosCore
import XCTest

final class ConnectionsBrowserModeTests: XCTestCase {
    func testAppSettingsModeRendersWithoutDismissChrome() {
        let mode: ConnectionsBrowserMode = .appSettings
        XCTAssertFalse(mode.showsDismissChrome)
        XCTAssertNil(mode.conversationId)
        XCTAssertNil(mode.agentInboxId)
    }

    func testComposerModalModeRendersWithDismissChrome() {
        let mode: ConnectionsBrowserMode = .composerModal(conversationId: "dm-1", agentInboxId: "agent-1")
        XCTAssertTrue(mode.showsDismissChrome)
        XCTAssertEqual(mode.conversationId, "dm-1")
        XCTAssertEqual(mode.agentInboxId, "agent-1")
    }

    func testModeIdentitiesAreDistinct() {
        let settings: ConnectionsBrowserMode = .appSettings
        let modal: ConnectionsBrowserMode = .composerModal(conversationId: "dm-1", agentInboxId: "agent-1")
        let otherModal: ConnectionsBrowserMode = .composerModal(conversationId: "dm-2", agentInboxId: "agent-1")
        XCTAssertNotEqual(settings.id, modal.id)
        XCTAssertNotEqual(modal.id, otherModal.id)
    }
}
