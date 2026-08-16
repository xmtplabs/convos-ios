import SwiftUI

/// Bridges `ConversationSheetDetent` onto the system's presentation detents so
/// the conversation sheet is a real `.sheet`: the system owns the drag, the
/// physics, the content-drag-to-resize handoff and the background
/// pass-through, and this only answers "how tall is each size, and which ones
/// are worth offering".
///
/// The measured sizes are concrete `.height(_:)` detents recomputed when the
/// measurements change, rather than a `CustomPresentationDetent` reading them out
/// of the environment through its `Context`. That does not work: custom
/// environment values do not reach that `Context`, from the sheet's content or
/// from the presenter, and the detent silently keeps its default.
extension ConversationSheetDetent {
    /// The system detent this size presents as, for a given set of measurements.
    func presentationDetent(heights: ConversationSheetHeights) -> PresentationDetent {
        switch self {
        case .collapsed:
            return .height(heights.restingHeight)
        case .compact:
            return .fraction(Constant.compactFraction)
        case .fitted:
            return .height(heights.fittedHeight)
        case .full:
            // `.large` stops at the top safe area, which already carries the
            // floating top bar - so it lands just under the conversation
            // indicator, which is where `full` belongs.
            return .large
        }
    }

    /// The sizes on offer, which depends on how much transcript there is.
    ///
    /// `fitted` is the ceiling: the sheet stops where the messages do, so a
    /// conversation with two messages in it cannot be dragged open onto most of a
    /// screen of nothing. The fixed sizes join it only when they earn a place:
    ///
    /// - `compact` when it sits meaningfully below the ceiling, so it is a stop on
    ///   the way rather than a second name for the same height.
    /// - `full` when the transcript reaches it, at which point it *is* the ceiling
    ///   and `fitted` would be a duplicate - and `.large` is the better spelling,
    ///   since the system fits it to the device rather than to our arithmetic.
    ///
    /// `current` is in there unconditionally. Dropping the resting detent out of
    /// the set makes the system re-resolve the selection and snap the sheet
    /// somewhere else, so a ceiling that falls has to leave the user where they
    /// are and only bind the next drag.
    static func presentationDetents(
        heights: ConversationSheetHeights,
        including current: ConversationSheetDetent
    ) -> Set<PresentationDetent> {
        var offered: Set<ConversationSheetDetent> = [.collapsed, current]
        let ceiling: CGFloat = ceilingHeight(heights: heights)
        let compactHeight: CGFloat = approximateHeight(of: .compact, heights: heights)
        let fullHeight: CGFloat = approximateHeight(of: .full, heights: heights)

        if compactHeight + Constant.distinctHeightThreshold < ceiling {
            offered.insert(.compact)
        }
        if ceiling + Constant.distinctHeightThreshold >= fullHeight {
            offered.insert(.full)
        } else {
            offered.insert(.fitted)
        }
        return Set(offered.map { $0.presentationDetent(heights: heights) })
    }

    /// The size matching a system detent. Unrecognized values resolve to
    /// `collapsed` - the least intrusive answer, and the one the sheet rests at.
    static func from(
        presentationDetent: PresentationDetent,
        heights: ConversationSheetHeights
    ) -> ConversationSheetDetent {
        ascending.first {
            $0.presentationDetent(heights: heights) == presentationDetent
        } ?? .collapsed
    }

    /// The tallest size actually on offer, for anything that wants to open the
    /// sheet as far as it goes. Asking for `full` outright would walk past the
    /// ceiling and undo the cap.
    static func tallestOffered(heights: ConversationSheetHeights) -> ConversationSheetDetent {
        let ceiling: CGFloat = ceilingHeight(heights: heights)
        let fullHeight: CGFloat = approximateHeight(of: .full, heights: heights)
        guard ceiling + Constant.distinctHeightThreshold < fullHeight else { return .full }
        return .fitted
    }

    /// The smallest size that shows any transcript, for opening the sheet on
    /// something the user asked to read.
    ///
    /// `compact` when it is on offer, otherwise the ceiling - which for a short
    /// conversation is only a little taller than the chrome, and is exactly as far
    /// as there is anything to see.
    static func smallestReadable(heights: ConversationSheetHeights) -> ConversationSheetDetent {
        let ceiling: CGFloat = ceilingHeight(heights: heights)
        let compactHeight: CGFloat = approximateHeight(of: .compact, heights: heights)
        guard compactHeight + Constant.distinctHeightThreshold < ceiling else { return .fitted }
        return .compact
    }

    /// How tall the sheet is allowed to get: the transcript's own height, never
    /// past the container and never below the chrome it has to contain.
    private static func ceilingHeight(heights: ConversationSheetHeights) -> CGFloat {
        min(max(heights.fittedHeight, heights.restingHeight), heights.containerHeight)
    }

    /// Roughly how tall a size resolves to, for deciding which ones are worth
    /// offering. The system owns the real numbers behind `.fraction` and `.large`,
    /// and approximate is enough here: this only gates availability, so being a
    /// few points out shifts a threshold by a message and never misplaces anything
    /// on screen.
    private static func approximateHeight(
        of detent: ConversationSheetDetent,
        heights: ConversationSheetHeights
    ) -> CGFloat {
        switch detent {
        case .collapsed:
            return heights.restingHeight
        case .compact:
            return heights.containerHeight * Constant.compactFraction
        case .fitted:
            return ceilingHeight(heights: heights)
        case .full:
            return heights.containerHeight
        }
    }

    private enum Constant {
        /// How much of the screen `compact` takes.
        static let compactFraction: CGFloat = 0.5
        /// How far apart two sizes have to be to be worth offering separately.
        /// Closer than this and a drag cannot tell them apart, so one of them is
        /// a stop that catches the sheet for no reason.
        static let distinctHeightThreshold: CGFloat = 60.0
    }
}
