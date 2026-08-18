@testable import Convos
import XCTest

/// The tab a conversation opens on. Home is the resting surface, so a
/// conversation with nothing to read starts there; unread messages pull the
/// user to the transcript holding them instead.
final class ConversationInitialTabTests: XCTestCase {
    private let allTabs: [ConversationTab] = ConversationTab.allCases
    private let noHome: [ConversationTab] = [.group, .agent]

    func testOpensOnHomeWhenNothingIsUnread() {
        let tab = ConversationTab.initial(
            available: allTabs,
            hasUnread: false,
            agentDmRequested: false
        )

        XCTAssertEqual(tab, .home)
    }

    func testUnreadOpensOnTheGroup() {
        let tab = ConversationTab.initial(
            available: allTabs,
            hasUnread: true,
            agentDmRequested: false
        )

        XCTAssertEqual(tab, .group, "a backlog must not sit behind another tab")
    }

    /// A DM notification, or a list row whose most recent unread is in the DM,
    /// asked for that surface specifically.
    func testAgentDmRequestWinsOutright() {
        XCTAssertEqual(
            ConversationTab.initial(available: allTabs, hasUnread: true, agentDmRequested: true),
            .agent
        )
        XCTAssertEqual(
            ConversationTab.initial(available: allTabs, hasUnread: false, agentDmRequested: true),
            .agent
        )
    }

    /// Home exists only once a Space URL has been published, which a brand-new
    /// conversation has not.
    func testFallsBackToTheGroupWithoutAHome() {
        let tab = ConversationTab.initial(
            available: noHome,
            hasUnread: false,
            agentDmRequested: false
        )

        XCTAssertEqual(tab, .group)
    }
}
