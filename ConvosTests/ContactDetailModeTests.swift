@testable import Convos
import ConvosCore
import XCTest

final class ContactDetailModeTests: XCTestCase {
    func testStandaloneModeReportsNonScoped() {
        let mode: ContactDetailMode = .standalone
        XCTAssertFalse(mode.isScopedToConversation)
        XCTAssertNil(mode.conversationId)
        XCTAssertFalse(mode.canRemoveMembers)
        XCTAssertFalse(mode.isCurrentUser)
    }

    func testScopedModeExposesPayload() {
        let mode: ContactDetailMode = .scopedToConversation(
            conversationId: "convo-1",
            canRemoveMembers: true,
            isCurrentUser: false,
            invitedBy: nil,
            joinedAt: nil
        )
        XCTAssertTrue(mode.isScopedToConversation)
        XCTAssertEqual(mode.conversationId, "convo-1")
        XCTAssertTrue(mode.canRemoveMembers)
        XCTAssertFalse(mode.isCurrentUser)
    }

    func testScopedModeCurrentUserFlag() {
        let mode: ContactDetailMode = .scopedToConversation(
            conversationId: "convo-1",
            canRemoveMembers: false,
            isCurrentUser: true,
            invitedBy: nil,
            joinedAt: nil
        )
        XCTAssertTrue(mode.isCurrentUser)
        XCTAssertFalse(mode.canRemoveMembers)
    }
}
