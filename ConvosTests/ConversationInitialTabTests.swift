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

        // `fitted`, not `full`: as much transcript as there is, which is the whole
        // screen for a backlog and a small card for two messages. Opening at `full`
        // regardless landed a short conversation on mostly empty space.
        XCTAssertEqual(detent, .fitted)
        XCTAssertTrue(detent.showsTranscript)
    }

    /// Asking for the DM outright opens it even with nothing unread.
    func testAgentDmRequestOpensOntoTheTranscript() {
        let detent = ConversationSheetDetent.initial(hasUnread: false, agentDmRequested: true)

        XCTAssertEqual(detent, .fitted)
    }
}
