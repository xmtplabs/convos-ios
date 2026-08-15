@testable import Convos
import SwiftUI
import XCTest

/// How the conversation sheet's sizes map onto system presentation detents.
/// The drag, the snapping and the physics belong to the presentation; what is
/// left to pin down is which detent each size resolves to for a given set of
/// measurements, and which sizes are offered at all.
final class ConversationSheetLayoutTests: XCTestCase {
    /// Chrome as measured on a 6.3" phone, and one short message.
    private let chrome: CGFloat = 151
    private let lastMessage: CGFloat = 60

    // MARK: - Content-driven heights

    func testCollapsedIsExactlyTheMeasuredChrome() {
        let detent = ConversationSheetDetent.collapsed.presentationDetent(
            chromeHeight: chrome,
            lastMessageHeight: lastMessage
        )

        XCTAssertEqual(detent, .height(151))
    }

    func testCompactAddsTheLastMessageToTheChrome() {
        let detent = ConversationSheetDetent.compact.presentationDetent(
            chromeHeight: chrome,
            lastMessageHeight: lastMessage
        )

        XCTAssertEqual(detent, .height(211))
    }

    /// A negative measurement is a measurement that has not happened; it must
    /// not shrink the sheet under its own chrome.
    func testANegativeMessageHeightIsIgnored() {
        let detent = ConversationSheetDetent.compact.presentationDetent(
            chromeHeight: chrome,
            lastMessageHeight: -40
        )

        XCTAssertEqual(detent, .height(151))
    }

    /// Full stops at the top safe area, which already carries the floating top
    /// bar - so it lands just under the conversation indicator.
    func testFullIsTheLargeDetent() {
        let detent = ConversationSheetDetent.full.presentationDetent(
            chromeHeight: chrome,
            lastMessageHeight: lastMessage
        )

        XCTAssertEqual(detent, .large)
    }

    // MARK: - Which sizes are offered

    /// Two detents at the same height are indistinguishable to a drag, and
    /// landing on compact would show the transcript at what looks like the
    /// collapsed size.
    func testCompactIsWithheldUntilAMessageIsMeasured() {
        let offered = ConversationSheetDetent.presentationDetents(
            chromeHeight: chrome,
            lastMessageHeight: 0
        )

        XCTAssertEqual(offered.count, 3)
        XCTAssertFalse(offered.contains(.height(151 + 0)))
        XCTAssertTrue(offered.contains(.height(151)), "collapsed is always offered")
    }

    func testCompactIsOfferedOnceAMessageIsMeasured() {
        let offered = ConversationSheetDetent.presentationDetents(
            chromeHeight: chrome,
            lastMessageHeight: lastMessage
        )

        XCTAssertEqual(offered.count, 4)
        XCTAssertTrue(offered.contains(.height(211)))
    }

    // MARK: - Reading the selection back

    /// The system writes its settled detent back through the selection
    /// binding, so every size has to survive the round trip.
    func testEverySizeRoundTrips() {
        for size in ConversationSheetDetent.ascending {
            let presentation = size.presentationDetent(
                chromeHeight: chrome,
                lastMessageHeight: lastMessage
            )
            let recovered = ConversationSheetDetent.from(
                presentationDetent: presentation,
                chromeHeight: chrome,
                lastMessageHeight: lastMessage
            )

            XCTAssertEqual(recovered, size)
        }
    }

    /// A detent the sheet never offered resolves to the least intrusive size
    /// rather than something arbitrary.
    func testAnUnknownDetentResolvesToCollapsed() {
        let recovered = ConversationSheetDetent.from(
            presentationDetent: .fraction(0.77),
            chromeHeight: chrome,
            lastMessageHeight: lastMessage
        )

        XCTAssertEqual(recovered, .collapsed)
    }

    /// `collapsed` is the one size that leaves the Home entirely uncovered.
    func testOnlyCollapsedHidesTheTranscript() {
        XCTAssertFalse(ConversationSheetDetent.collapsed.showsTranscript)
        for detent in ConversationSheetDetent.ascending.filter({ $0 != .collapsed }) {
            XCTAssertTrue(detent.showsTranscript, "\(detent) should show transcript content")
        }
    }
}
