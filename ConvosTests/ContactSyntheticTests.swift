import ConvosCore
import XCTest

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
