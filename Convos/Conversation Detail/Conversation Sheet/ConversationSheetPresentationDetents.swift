import SwiftUI

/// Bridges `ConversationSheetDetent` onto the system's presentation detents so
/// the conversation sheet is a real `.sheet`: the system owns the drag, the
/// physics, the content-drag-to-resize handoff and the background
/// pass-through, and this only answers "how tall is each size".
///
/// Only one height is measured - the sheet's resting height, which the chrome
/// publishes - and it is expressed as a concrete `.height(_:)` detent rather
/// than a `CustomPresentationDetent` reading the measurement out of the
/// environment through its `Context`. That does not work: custom environment
/// values do not reach that `Context`, from the sheet's content or from the
/// presenter, and the detent silently keeps its default. Recomputing the set
/// when the measurement changes is what makes the sizes track the chrome.
extension ConversationSheetDetent {
    /// The system detent this size presents as, for a given resting height.
    func presentationDetent(restingHeight: CGFloat) -> PresentationDetent {
        switch self {
        case .collapsed:
            return .height(restingHeight)
        case .compact:
            return .fraction(Constant.compactFraction)
        case .full:
            // `.large` stops at the top safe area, which already carries the
            // floating top bar - so it lands just under the conversation
            // indicator, which is where `full` belongs.
            return .large
        }
    }

    /// Every size, as the set handed to `presentationDetents`.
    static func presentationDetents(restingHeight: CGFloat) -> Set<PresentationDetent> {
        Set(ascending.map { $0.presentationDetent(restingHeight: restingHeight) })
    }

    /// The size matching a system detent. Unrecognized values resolve to
    /// `collapsed` - the least intrusive answer, and the one the sheet rests
    /// at.
    static func from(presentationDetent: PresentationDetent, restingHeight: CGFloat) -> ConversationSheetDetent {
        ascending.first {
            $0.presentationDetent(restingHeight: restingHeight) == presentationDetent
        } ?? .collapsed
    }

    /// The largest size at which the Home behind the sheet stays touchable.
    /// Above this the sheet has covered it anyway.
    static var backgroundInteractionCeiling: PresentationDetent {
        .fraction(Constant.compactFraction)
    }

    private enum Constant {
        /// How much of the screen `compact` takes.
        static let compactFraction: CGFloat = 0.5
    }
}
