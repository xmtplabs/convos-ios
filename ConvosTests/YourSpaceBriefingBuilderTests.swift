@testable import Convos
import ConvosCore
import XCTest

final class YourSpaceBriefingBuilderTests: XCTestCase {
    func testHeadlineConnectsUnreadUpdatesAcrossConversations() {
        let studio = Conversation.mock(
            id: "studio",
            name: "Studio",
            isUnread: true,
            lastMessageText: "Molly: The launch notes are ready"
        )
        let nash = Conversation.mock(
            id: "nash",
            name: "Nash",
            isUnread: true,
            lastMessageText: "Nick: Dropped his favorite restaurants"
        )
        let newYorkTrip = Conversation.mock(
            id: "new-york-trip",
            name: "New York Trip",
            isUnread: true,
            lastMessageText: "Saul: Added 13 places"
        )
        let briefing = YourSpaceBriefingBuilder.make(conversations: [studio, nash, newYorkTrip])

        XCTAssertEqual(briefing.sourceCount, 3)
        XCTAssertEqual(briefing.attentionCount, 3)
        XCTAssertTrue(briefing.headline.contains("New York Trip"))
        XCTAssertTrue(briefing.headline.contains("Nash"))
        XCTAssertTrue(briefing.headline.contains("1 more convo has new context"))
        XCTAssertFalse(briefing.headline.contains("Saul"))
        XCTAssertFalse(briefing.headline.contains("Nick"))
    }

    func testReadConversationsProduceCaughtUpHeadline() {
        let briefing = YourSpaceBriefingBuilder.make(conversations: [
            .mock(id: "family", name: "Family"),
            .mock(id: "studio", name: "Studio"),
        ])

        XCTAssertEqual(briefing.attentionCount, 0)
        XCTAssertEqual(
            briefing.headline,
            "Nothing needs you right now. Your Space is quietly keeping up with 2 convos."
        )
    }

    func testSharingKeepsConversationProvenanceWithoutInventingSender() throws {
        let briefing = YourSpaceBriefingBuilder.make(conversations: [
            .mock(
                id: "nash",
                name: "Nash",
                isUnread: true,
                lastMessageText: "Nick: Dropped his favorite restaurants"
            ),
        ])

        let update = try XCTUnwrap(briefing.recentUpdates.first)
        XCTAssertNil(update.personName)
        XCTAssertEqual(update.conversationTitle, "Nash")
        XCTAssertEqual(update.detail, "Nick: Dropped his favorite restaurants")
        XCTAssertEqual(update.shareText, "Nash: Nick: Dropped his favorite restaurants")
    }
}
