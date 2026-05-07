import ConvosCore
import XCTest
@testable import Convos

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

final class ContactSyntheticTests: XCTestCase {
    func testSyntheticContactCarriesProvidedFields() {
        let contact = Contact.synthetic(
            inboxId: "inbox-1",
            displayName: "Alice",
            avatarURL: "https://example.com/a.png",
            addedViaConversationId: "convo-1",
            agentVerification: .verified(.convos)
        )
        XCTAssertEqual(contact.inboxId, "inbox-1")
        XCTAssertEqual(contact.displayName, "Alice")
        XCTAssertEqual(contact.avatarURL, "https://example.com/a.png")
        XCTAssertEqual(contact.addedViaConversationId, "convo-1")
        XCTAssertEqual(contact.agentVerification, .verified(.convos))
        XCTAssertFalse(contact.isBlocked)
        XCTAssertNil(contact.bio)
    }

    func testSyntheticContactDefaultsToNotBlockedAndNilAgent() {
        let contact = Contact.synthetic(
            inboxId: "inbox-2",
            displayName: nil,
            avatarURL: nil,
            addedViaConversationId: nil,
            agentVerification: nil
        )
        XCTAssertFalse(contact.isBlocked)
        XCTAssertNil(contact.agentVerification)
        XCTAssertNil(contact.addedViaConversationId)
    }
}
