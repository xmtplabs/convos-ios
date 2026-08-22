@testable import Convos
import XCTest

/// What a conversation opens on, and which of the three tabs carry a
/// transcript.
///
/// There is no detent half to this any more. The conversation used to open onto
/// a Space with a sheet over it, so "which tab" and "is that tab showing" were
/// separate questions; the tab is the whole answer now.
final class ConversationInitialTabTests: XCTestCase {
    private let allTabs: [ConversationTab] = ConversationTab.allCases
    private let groupOnly: [ConversationTab] = [.group]

    // MARK: - Which tab

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

    /// Context is the surface being demoted. Nothing routes an open to it -
    /// landing on the Space unasked is what this hierarchy exists to stop.
    func testNeverOpensOnContext() {
        let cases: [(Bool, Bool)] = [(false, false), (true, false), (false, true), (true, true)]
        for (requested, dmUnread) in cases {
            let tab = ConversationTab.initial(
                available: allTabs,
                agentDmRequested: requested,
                agentDmHoldsTheUnread: dmUnread
            )

            XCTAssertNotEqual(tab, .context, "requested: \(requested), dmUnread: \(dmUnread)")
        }
    }

    // MARK: - Which tabs carry a transcript

    /// The read-state machinery keys off this rather than naming `.context`, so
    /// it has to stay true of exactly the two transcripts.
    func testOnlyTheTranscriptTabsHostOne() {
        XCTAssertTrue(ConversationTab.group.hostsTranscript)
        XCTAssertTrue(ConversationTab.agent.hostsTranscript)
        XCTAssertFalse(ConversationTab.context.hostsTranscript)
    }

    /// Context is a web view: there is nothing to type into.
    func testContextHostsNoComposer() {
        XCTAssertTrue(ConversationTab.group.hostsComposer)
        XCTAssertTrue(ConversationTab.agent.hostsComposer)
        XCTAssertFalse(ConversationTab.context.hostsComposer)
    }

    /// Display order is the order the segmented control renders.
    func testTabsAreOrderedGroupAgentContext() {
        XCTAssertEqual(ConversationTab.allCases, [.group, .agent, .context])
    }

    func testTitlesMatchTheDesign() {
        XCTAssertEqual(ConversationTab.group.title, "Group")
        XCTAssertEqual(ConversationTab.agent.title, "Agent")
        XCTAssertEqual(ConversationTab.context.title, "Things")
    }
}
