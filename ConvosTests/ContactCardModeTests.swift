@testable import Convos
import ConvosCore
import XCTest

final class ContactCardModeTests: XCTestCase {
    func testStandaloneModeReportsNonScoped() {
        let mode: ContactCardMode = .standalone
        XCTAssertFalse(mode.isScopedToConversation)
        XCTAssertNil(mode.conversationId)
        XCTAssertFalse(mode.canRemoveMembers)
        XCTAssertFalse(mode.isCurrentUser)
    }

    func testScopedModeExposesPayload() {
        let mode: ContactCardMode = .scopedToConversation(
            conversationId: "convo-1",
            canRemoveMembers: true,
            isCurrentUser: false
        )
        XCTAssertTrue(mode.isScopedToConversation)
        XCTAssertEqual(mode.conversationId, "convo-1")
        XCTAssertTrue(mode.canRemoveMembers)
        XCTAssertFalse(mode.isCurrentUser)
    }

    func testScopedModeCurrentUserFlag() {
        let mode: ContactCardMode = .scopedToConversation(
            conversationId: "convo-1",
            canRemoveMembers: false,
            isCurrentUser: true
        )
        XCTAssertTrue(mode.isCurrentUser)
        XCTAssertFalse(mode.canRemoveMembers)
    }
}
