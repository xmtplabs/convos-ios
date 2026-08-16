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

    // MARK: - Sizing to the transcript

    /// Heights as measured on a 6.3" phone, with a transcript of `transcript`.
    private func heights(transcript: CGFloat, container: CGFloat = 815) -> ConversationSheetHeights {
        ConversationSheetHeights(
            restingHeight: resting,
            fittedHeight: resting + transcript,
            containerHeight: container
        )
    }

    /// The ceiling is the transcript's own height, so two messages cannot be
    /// dragged open onto most of a screen of nothing: neither `compact` nor `full`
    /// is on offer, only the size that stops just past them.
    func testAShortTranscriptOffersNeitherCompactNorFull() {
        let offered = ConversationSheetDetent.presentationDetents(
            heights: heights(transcript: 120),
            including: .collapsed
        )

        XCTAssertEqual(offered.count, 2)
        XCTAssertTrue(offered.contains(.height(resting)), "collapsed is always offered")
        XCTAssertTrue(offered.contains(.height(resting + 120)), "the ceiling is the transcript")
        XCTAssertFalse(offered.contains(.large))
    }

    /// `compact` joins once it sits meaningfully below the ceiling - a stop on the
    /// way rather than a second name for the same height.
    func testCompactJoinsOnceTheCeilingClearsIt() {
        let justBelow = ConversationSheetDetent.presentationDetents(
            heights: heights(transcript: 815 * 0.5 - resting),
            including: .collapsed
        )
        let wellAbove = ConversationSheetDetent.presentationDetents(
            heights: heights(transcript: 815 * 0.5),
            including: .collapsed
        )

        XCTAssertFalse(justBelow.contains(.fraction(0.5)))
        XCTAssertTrue(wellAbove.contains(.fraction(0.5)))
    }

    /// A transcript that reaches the container offers `full` instead of a fitted
    /// height of its own: they are the same size, and `.large` is the better
    /// spelling because the system fits it to the device.
    func testATranscriptThatFillsTheScreenOffersFull() {
        let offered = ConversationSheetDetent.presentationDetents(
            heights: heights(transcript: 5_000),
            including: .collapsed
        )

        XCTAssertTrue(offered.contains(.large))
        XCTAssertFalse(offered.contains(.height(resting + 5_000)), "the ceiling never passes the container")
    }

    /// Every height handed to the system has to be a real measurement or a real
    /// detent - never a stand-in for "not measured yet".
    ///
    /// `fitted` is the initial size for a conversation with something unread, so it
    /// resolves before anything has been measured. A sentinel here went to
    /// `PresentationDetent.height(_:)` as the sheet's own height, which is a launch
    /// crash for anyone opening the app on an unread conversation.
    func testAnUnmeasuredFittedSizeResolvesToARealDetent() {
        let fitted = ConversationSheetDetent.fitted.presentationDetent(heights: .unmeasured)

        XCTAssertEqual(fitted, .large)
        // The value the sentinel used to produce. `PresentationDetent` is opaque,
        // so equality against it is the only way to say "not that".
        XCTAssertNotEqual(fitted, .height(.greatestFiniteMagnitude))
    }

    /// Nothing is withheld before the transcript has measured itself - a sheet
    /// capped against a transcript of unknown height would open barely taller than
    /// its own chrome.
    func testAnUnmeasuredTranscriptWithholdsNothing() {
        let offered = ConversationSheetDetent.presentationDetents(
            heights: .unmeasured,
            including: .collapsed
        )

        XCTAssertTrue(offered.contains(.large))
        XCTAssertTrue(offered.contains(.fraction(0.5)))
    }

    /// Dropping the resting detent out of the set makes the system re-resolve the
    /// selection and snap the sheet, so a ceiling that falls has to leave the user
    /// where they are.
    func testTheRestingSizeIsOfferedEvenAboveTheCeiling() {
        let offered = ConversationSheetDetent.presentationDetents(
            heights: heights(transcript: 120),
            including: .full
        )

        XCTAssertTrue(offered.contains(.large))
    }

    /// Opening on an unread message uses the smallest size that shows anything,
    /// which for a short conversation is the ceiling rather than half a screen.
    func testTheSmallestReadableSizeFollowsTheTranscript() {
        XCTAssertEqual(ConversationSheetDetent.smallestReadable(heights: heights(transcript: 120)), .fitted)
        XCTAssertEqual(ConversationSheetDetent.smallestReadable(heights: heights(transcript: 5_000)), .compact)
    }

    /// The system writes its settled detent back through the selection binding, so
    /// every size has to survive the round trip.
    func testEverySizeRoundTrips() {
        let measurements = heights(transcript: 300)
        for size in ConversationSheetDetent.ascending {
            let presentation = size.presentationDetent(heights: measurements)
            let recovered = ConversationSheetDetent.from(
                presentationDetent: presentation,
                heights: measurements
            )

            XCTAssertEqual(recovered, size)
        }
    }

    /// A detent the sheet never offered resolves to the least intrusive size.
    func testAnUnknownDetentResolvesToCollapsed() {
        let recovered = ConversationSheetDetent.from(
            presentationDetent: .fraction(0.77),
            heights: heights(transcript: 300)
        )

        XCTAssertEqual(recovered, .collapsed)
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
