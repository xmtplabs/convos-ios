@testable import Convos
import XCTest

/// Heights for the conversation sheet's content-driven detents. The drag,
/// the snapping and the physics belong to the system presentation now, so what
/// is left to pin down is the arithmetic the custom detents answer with.
final class ConversationSheetLayoutTests: XCTestCase {
    /// A 6.3" phone: the presentation's ceiling once the safe area is taken,
    /// measured chrome, and one short message in the transcript.
    private let maxDetent: CGFloat = 732
    private let chrome: CGFloat = 172
    private let topGap: CGFloat = 8

    // MARK: - collapsed

    func testCollapsedIsExactlyTheMeasuredChrome() {
        let height = ConversationSheetDetentHeights.collapsed(chrome: chrome, maxDetent: maxDetent)

        XCTAssertEqual(height, 172)
    }

    /// A tall composer (attachments, a reply bar) on a short screen must not
    /// ask for more than the presentation can give.
    func testCollapsedCannotExceedThePresentation() {
        let height = ConversationSheetDetentHeights.collapsed(chrome: 900, maxDetent: maxDetent)

        XCTAssertEqual(height, maxDetent)
    }

    // MARK: - compact

    func testCompactAddsTheLastMessageToTheChrome() {
        let height = ConversationSheetDetentHeights.compact(
            chrome: chrome,
            lastMessage: 60,
            maxDetent: maxDetent
        )

        XCTAssertEqual(height, 232)
    }

    /// Before the transcript reports a message height there is nothing to
    /// show, so compact must not open a blank gap above the composer.
    func testCompactCollapsesWithoutAMeasuredMessage() {
        let compact = ConversationSheetDetentHeights.compact(
            chrome: chrome,
            lastMessage: 0,
            maxDetent: maxDetent
        )
        let collapsed = ConversationSheetDetentHeights.collapsed(chrome: chrome, maxDetent: maxDetent)

        XCTAssertEqual(compact, collapsed)
    }

    /// A very tall message would otherwise push compact over the conversation
    /// indicator.
    func testATallMessageCannotPushCompactPastThePresentation() {
        let height = ConversationSheetDetentHeights.compact(
            chrome: chrome,
            lastMessage: 5_000,
            maxDetent: maxDetent
        )

        XCTAssertEqual(height, maxDetent)
    }

    /// A negative measurement is a measurement that has not happened; it must
    /// not shrink the sheet under its own chrome.
    func testANegativeMessageHeightIsIgnored() {
        let height = ConversationSheetDetentHeights.compact(
            chrome: chrome,
            lastMessage: -40,
            maxDetent: maxDetent
        )

        XCTAssertEqual(height, chrome)
    }

    // MARK: - full

    /// Full stops below the conversation indicator rather than filling the
    /// presentation.
    func testFullStopsBelowTheTopGap() {
        let height = ConversationSheetDetentHeights.full(
            chrome: chrome,
            maxDetent: maxDetent,
            topGap: topGap
        )

        XCTAssertEqual(height, 724)
    }

    /// On a container barely taller than the chrome, backing off the gap would
    /// put full under its own composer.
    func testFullNeverResolvesShorterThanTheChrome() {
        let height = ConversationSheetDetentHeights.full(
            chrome: chrome,
            maxDetent: 174,
            topGap: topGap
        )

        XCTAssertEqual(height, chrome)
    }

    // MARK: - Ordering

    /// The on-screen sizes have to follow the enum's order, or a drag settles
    /// somewhere that reads as a different detent than the one selected.
    func testDetentHeightsAreOrderedSmallestToLargest() {
        let heights: [CGFloat] = [
            ConversationSheetDetentHeights.collapsed(chrome: chrome, maxDetent: maxDetent),
            ConversationSheetDetentHeights.compact(chrome: chrome, lastMessage: 60, maxDetent: maxDetent),
            maxDetent / 2,
            ConversationSheetDetentHeights.full(chrome: chrome, maxDetent: maxDetent, topGap: topGap),
        ]

        XCTAssertEqual(heights, heights.sorted())
    }

    /// `collapsed` is the one size that leaves the Home entirely uncovered.
    func testOnlyCollapsedHidesTheTranscript() {
        XCTAssertFalse(ConversationSheetDetent.collapsed.showsTranscript)
        for detent in ConversationSheetDetent.ascending.filter({ $0 != .collapsed }) {
            XCTAssertTrue(detent.showsTranscript, "\(detent) should show transcript content")
        }
    }
}
