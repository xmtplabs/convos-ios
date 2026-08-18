@testable import Convos
import XCTest

/// What a conversation opens on. The tab picks which transcript the sheet
/// hosts; the detent decides whether that transcript is showing at all, since
/// the Home sits behind the sheet at every size.
final class ConversationInitialTabTests: XCTestCase {
    private let allTabs: [ConversationTab] = ConversationTab.allCases
    private let groupOnly: [ConversationTab] = [.group]

    // MARK: - Which transcript

    func testOpensOnTheGroupByDefault() {
        let tab = ConversationTab.initial(available: allTabs, agentDmRequested: false)

        XCTAssertEqual(tab, .group)
    }

    /// A DM notification, or a list row whose most recent unread is in the DM,
    /// asked for that surface specifically.
    func testAgentDmRequestOpensTheDm() {
        let tab = ConversationTab.initial(available: allTabs, agentDmRequested: true)

        XCTAssertEqual(tab, .agent)
    }

    /// A host that withheld the agent tab must not be handed it.
    func testAgentRequestFallsBackWhenTheTabIsUnavailable() {
        let tab = ConversationTab.initial(available: groupOnly, agentDmRequested: true)

        XCTAssertEqual(tab, .group)
    }

    /// Opening onto the group would show a read transcript while the dot sat on
    /// the other tab, so the lane holding the unread gets the open.
    func testAnUnreadDmOpensTheDmWithoutBeingAskedFor() {
        let tab = ConversationTab.initial(
            available: allTabs,
            agentDmRequested: false,
            agentDmHoldsTheUnread: true
        )

        XCTAssertEqual(tab, .agent)
    }

    /// With both lanes unread the group wins - it is the conversation the list row
    /// was for. The host decides this by only reporting the DM when the group has
    /// nothing of its own.
    func testTheGroupKeepsTheOpenWhenItAlsoHasSomethingUnread() {
        let tab = ConversationTab.initial(
            available: allTabs,
            agentDmRequested: false,
            agentDmHoldsTheUnread: false
        )

        XCTAssertEqual(tab, .group)
    }

    // MARK: - How much of it is showing

    /// Nothing to read means the Home is the point, so the sheet leaves it
    /// uncovered.
    func testNothingUnreadRestsCollapsedOverTheHome() {
        let detent = ConversationSheetDetent.initial(hasUnread: false, agentDmRequested: false)

        XCTAssertEqual(detent, .collapsed)
        XCTAssertFalse(detent.showsTranscript)
    }

    /// A backlog must not sit hidden behind the Home.
    func testUnreadOpensOntoTheTranscript() {
        let detent = ConversationSheetDetent.initial(hasUnread: true, agentDmRequested: false)

        // `compact`, not `full`: opening a conversation is not a request to
        // be taken to full screen. The unread message is at the bottom, half a
        // screen shows it and its context, and the Home stays in view.
        XCTAssertEqual(detent, .compact)
        XCTAssertTrue(detent.showsTranscript)
    }

    /// Asking for the DM outright opens it even with nothing unread.
    func testAgentDmRequestOpensOntoTheTranscript() {
        let detent = ConversationSheetDetent.initial(hasUnread: false, agentDmRequested: true)

        XCTAssertEqual(detent, .compact)
    }
}
