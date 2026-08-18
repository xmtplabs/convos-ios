@testable import Convos
import SwiftUI
import XCTest

/// How the conversation sheet's sizes map onto system presentation detents.
/// The drag, the snapping and the physics belong to the presentation; what is
/// left to pin down is which detent each size resolves to for a given resting
/// height, and how the chrome's own height is assembled.
final class ConversationSheetLayoutTests: XCTestCase {
    /// The sheet's resting height as measured on a 6.3" phone.
    private let resting: CGFloat = 151

    // MARK: - The sizes

    private var measurements: ConversationSheetHeights {
        ConversationSheetHeights(restingHeight: resting)
    }

    /// Three fixed sizes, always all on offer.
    ///
    /// The set used to depend on the selected lane's transcript, which meant it was
    /// rebuilt underneath a live sheet whenever a transcript re-measured, and meant
    /// the same detent was two different heights on the two tabs. Nothing here
    /// depends on either any more, so the set is built once.
    func testEverySizeIsAlwaysOffered() {
        let offered = ConversationSheetDetent.presentationDetents(heights: measurements)

        XCTAssertEqual(offered, [.height(resting), .fraction(0.5), .large])
    }

    /// The chrome's height is the only measurement a size depends on, so the set is
    /// the same shape before it has been taken.
    func testTheSetHasTheSameShapeBeforeTheChromeIsMeasured() {
        let offered = ConversationSheetDetent.presentationDetents(heights: .unmeasured)

        XCTAssertEqual(offered.count, 3)
        XCTAssertTrue(offered.contains(.fraction(0.5)))
        XCTAssertTrue(offered.contains(.large))
    }

    /// A move the user did not make offers a single size until it lands.
    ///
    /// With one size on offer there is no selection for the system to re-resolve,
    /// so it resizes in one step with the presented view's bottom edge pinned - the
    /// same shape as a drag. Offering the full set instead let the origin land on
    /// the new size a layout pass before the height did, and the bottom-anchored
    /// chrome rode the difference off the screen and back.
    func testAForcedMoveOffersOneSize() {
        let offered = ConversationSheetDetent.presentationDetents(
            heights: measurements,
            forcing: .compact
        )

        XCTAssertEqual(offered, [.fraction(0.5)])
    }

    /// Opening on an unread message shows the transcript without taking the screen.
    func testTheSmallestReadableSizeIsCompact() {
        XCTAssertEqual(ConversationSheetDetent.smallestReadable, .compact)
        XCTAssertEqual(ConversationSheetDetent.tallest, .full)
    }

    /// The system writes its settled detent back through the selection binding, so
    /// every size has to survive the round trip.
    func testEverySizeRoundTrips() {
        for size in ConversationSheetDetent.ascending {
            let presentation = size.presentationDetent(heights: measurements)
            let recovered = ConversationSheetDetent.from(
                presentationDetent: presentation,
                heights: measurements
            )

            XCTAssertEqual(recovered, size)
        }
    }

    /// A detent these measurements do not describe resolves to nothing, so the
    /// caller leaves the sheet where it is.
    ///
    /// Deliberately not `collapsed`. This runs on the way back in, where the answer
    /// is written into the sheet's detent - so a fallback would be an instruction to
    /// collapse, issued every time a detent in flight outlived the heights that
    /// produced it.
    func testAnUnknownDetentResolvesToNothing() {
        let recovered = ConversationSheetDetent.from(
            presentationDetent: .fraction(0.77),
            heights: measurements
        )

        XCTAssertNil(recovered)
    }

    // MARK: - What the Home keeps clear

    /// The clearance is the sheet's own measured coverage, bounded by two heights
    /// measured the same way - never a fraction of some other view, which is not
    /// comparable to it and leaves the page short of the sheet's edge.
    @MainActor
    func testTheHomeClearanceIsTheSheetsCoverageWithinItsBounds() {
        let geometry = ConversationSheetGeometry()
        geometry.restingHeight = resting
        geometry.containerHeight = 800

        geometry.coveredHeight = 415
        XCTAssertEqual(geometry.homeBottomClearance, 415, "follows the sheet between its bounds")

        geometry.coveredHeight = 40
        XCTAssertEqual(geometry.homeBottomClearance, resting, "never below the resting height")

        geometry.coveredHeight = 900
        XCTAssertEqual(geometry.homeBottomClearance, 800, "never past a fully covered Home")
    }

    /// Before the container has been measured there is no ceiling to apply, and
    /// clamping to zero would drop the clearance to nothing.
    @MainActor
    func testTheHomeClearanceIgnoresAnUnmeasuredCeiling() {
        let geometry = ConversationSheetGeometry()
        geometry.restingHeight = resting
        geometry.coveredHeight = 415

        XCTAssertEqual(geometry.homeBottomClearance, 415)
    }

    /// `collapsed` is the one size that leaves the Home entirely uncovered.
    func testOnlyCollapsedHidesTheTranscript() {
        XCTAssertFalse(ConversationSheetDetent.collapsed.showsTranscript)
        for detent in ConversationSheetDetent.ascending.filter({ $0 != .collapsed }) {
            XCTAssertTrue(detent.showsTranscript, "\(detent) should show transcript content")
        }
    }

    // MARK: - How the chrome's height is assembled

    /// The band above the input bar is the one part of the chrome that moves:
    /// at `collapsed` the sheet's top edge is the chrome's, so the drag
    /// indicator has to be cleared before the bar can sit at the same gap the
    /// bar and tab bar share. Above `collapsed` the indicator is up at the
    /// sheet's own edge and the bar wants nothing but the gap.
    func testOnlyCollapsedClearsTheDragIndicator() {
        let collapsed = ConversationSheetMetrics.chromeTopPadding(for: .collapsed)
        let spacing = ConversationSheetMetrics.chromeContentSpacing

        XCTAssertEqual(collapsed, spacing + ConversationSheetMetrics.dragIndicatorAllowance)
        for detent in ConversationSheetDetent.ascending.filter({ $0 != .collapsed }) {
            XCTAssertEqual(ConversationSheetMetrics.chromeTopPadding(for: detent), spacing)
        }
    }

    /// The resting height must not follow the chrome's current height, or every
    /// collapse would land short by the drag indicator's band and then grow
    /// back once the band returned.
    func testTheRestingHeightIsTheCollapsedGeometryWhateverTheSheetIsDoing() {
        let bars: CGFloat = 123

        XCTAssertEqual(
            ConversationSheetMetrics.collapsedChromeHeight(barsHeight: bars),
            ConversationSheetMetrics.chromeHeight(barsHeight: bars, detent: .collapsed)
        )
        for detent in ConversationSheetDetent.ascending.filter({ $0 != .collapsed }) {
            XCTAssertLessThan(
                ConversationSheetMetrics.chromeHeight(barsHeight: bars, detent: detent),
                ConversationSheetMetrics.collapsedChromeHeight(barsHeight: bars)
            )
        }
    }
}
