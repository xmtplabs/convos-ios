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

    // MARK: - Content-driven heights

    func testCollapsedIsExactlyTheRestingHeight() {
        let detent = ConversationSheetDetent.collapsed.presentationDetent(restingHeight: resting)

        XCTAssertEqual(detent, .height(151))
    }

    /// Compact shows a fixed band of transcript above the chrome rather than the
    /// last message's measured height, which changed as messages arrived and
    /// resized the sheet under the reader.
    func testCompactAddsAFixedTranscriptBandToTheRestingHeight() {
        let detent = ConversationSheetDetent.compact.presentationDetent(restingHeight: resting)

        XCTAssertEqual(detent, .height(151 + 96))
    }

    /// Full stops at the top safe area, which already carries the floating top
    /// bar - so it lands just under the conversation indicator.
    func testFullIsTheLargeDetent() {
        let detent = ConversationSheetDetent.full.presentationDetent(restingHeight: resting)

        XCTAssertEqual(detent, .large)
    }

    // MARK: - Which sizes are offered

    /// Every size is offered at once: none of them collapse onto each other now
    /// that compact carries a band of its own.
    func testEverySizeIsOffered() {
        let offered = ConversationSheetDetent.presentationDetents(restingHeight: resting)

        XCTAssertEqual(offered.count, ConversationSheetDetent.ascending.count)
        XCTAssertTrue(offered.contains(.height(151)))
        XCTAssertTrue(offered.contains(.height(151 + 96)))
    }

    // MARK: - Where the Home stops following the sheet

    /// The Home's bottom clearance stops growing at the height where the Home
    /// stops taking touches, so the two have to be the same size: a ceiling
    /// anywhere else would leave the page either following a sheet it can no
    /// longer be scrolled clear of, or stopping while it still can be.
    func testTheHomeCeilingIsTheDetentBackgroundInteractionStopsAt() {
        XCTAssertEqual(
            ConversationSheetDetent.backgroundInteractionCeiling,
            ConversationSheetDetent.half.presentationDetent(restingHeight: resting)
        )
        XCTAssertEqual(
            ConversationSheetDetent.backgroundInteractionCeilingHeight(containerHeight: 800),
            400
        )
    }

    // MARK: - Reading the selection back

    /// The system writes its settled detent back through the selection
    /// binding, so every size has to survive the round trip.
    func testEverySizeRoundTrips() {
        for size in ConversationSheetDetent.ascending {
            let presentation = size.presentationDetent(restingHeight: resting)
            let recovered = ConversationSheetDetent.from(
                presentationDetent: presentation,
                restingHeight: resting
            )

            XCTAssertEqual(recovered, size)
        }
    }

    /// A detent the sheet never offered resolves to the least intrusive size
    /// rather than something arbitrary.
    func testAnUnknownDetentResolvesToCollapsed() {
        let recovered = ConversationSheetDetent.from(
            presentationDetent: .fraction(0.77),
            restingHeight: resting
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
