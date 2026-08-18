import SwiftUI

/// Bridges `ConversationSheetDetent` onto the system's presentation detents so
/// the conversation sheet is a real `.sheet`: the system owns the drag, the
/// physics, the content-drag-to-resize handoff and the background
/// pass-through, and this only answers "how tall is each size".
///
/// `collapsed` is a concrete `.height(_:)` detent recomputed when the chrome
/// measures itself, rather than a `CustomPresentationDetent` reading the height
/// out of the environment through its `Context`. That does not work: custom
/// environment values do not reach that `Context`, from the sheet's content or
/// from the presenter, and the detent silently keeps its default.
extension ConversationSheetDetent {
    /// The system detent this size presents as.
    func presentationDetent(heights: ConversationSheetHeights) -> PresentationDetent {
        switch self {
        case .collapsed:
            return .height(heights.restingHeight)
        case .compact:
            return .fraction(Constant.compactFraction)
        case .full:
            // `.large` stops at the top safe area, which already carries the
            // floating top bar - so it lands just under the conversation
            // indicator, which is where `full` belongs.
            return .large
        }
    }

    /// The sizes on offer, which is all of them.
    ///
    /// Every size is either a fixed fraction of the screen or a measurement of
    /// the chrome, so this set only changes when the chrome's own height does - a
    /// rotation, or the composer growing a line. It does not depend on which tab
    /// is selected, nor on how much transcript there is, and that is what keeps
    /// the system from re-resolving a selection it was already holding.
    ///
    /// `forced` is the one exception, and it is deliberate: a move the user did
    /// not make offers a single size until it lands. See
    /// `ConversationView.moveSheet`.
    static func presentationDetents(
        heights: ConversationSheetHeights,
        forcing forced: ConversationSheetDetent? = nil
    ) -> Set<PresentationDetent> {
        if let forced {
            return [forced.presentationDetent(heights: heights)]
        }
        return Set(ascending.map { $0.presentationDetent(heights: heights) })
    }

    /// The size matching a system detent, or `nil` for one these measurements do
    /// not describe.
    ///
    /// Nil rather than a fallback, and that distinction is load-bearing. This runs
    /// on the way *back* in - the system reports what it settled on and the answer
    /// is written into the sheet's own detent - so a fallback is not a lenient
    /// reading of an odd value, it is an instruction. Resolving an unrecognized
    /// detent to `collapsed` sent the sheet down whenever the system reported a
    /// height these measurements had just stopped describing.
    ///
    /// The caller's job is to leave the detent alone when this is nil. Nothing is
    /// lost by waiting: the system reports again once it settles.
    static func from(
        presentationDetent: PresentationDetent,
        heights: ConversationSheetHeights
    ) -> ConversationSheetDetent? {
        ascending.first {
            $0.presentationDetent(heights: heights) == presentationDetent
        }
    }

    private enum Constant {
        /// How much of the screen `compact` takes.
        static let compactFraction: CGFloat = 0.5
    }
}
