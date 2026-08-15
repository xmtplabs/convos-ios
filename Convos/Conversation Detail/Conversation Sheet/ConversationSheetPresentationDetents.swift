import SwiftUI

/// Bridges `ConversationSheetDetent` onto the system's presentation detents so
/// the conversation sheet is a real `.sheet`: the system owns the drag, the
/// physics, the content-drag-to-resize handoff and the background
/// pass-through, and this only answers "how tall is each size".
///
/// Two of the four heights are content-driven, and they are expressed as
/// concrete `.height(_:)` detents computed from the current measurements. The
/// obvious-looking alternative - a `CustomPresentationDetent` reading the
/// measurement out of the environment through its `Context` - does not work:
/// custom environment values do not reach that `Context`, from the sheet's
/// content or from the presenter, and the detent silently keeps its default.
/// Recomputing the set when a measurement changes is what makes the sizes
/// track the content.
extension ConversationSheetDetent {
    /// The system detent this size presents as, for the given measurements.
    func presentationDetent(chromeHeight: CGFloat, lastMessageHeight: CGFloat) -> PresentationDetent {
        switch self {
        case .collapsed:
            return .height(chromeHeight)
        case .compact:
            return .height(chromeHeight + Constant.compactTranscriptHeight)
        case .half:
            return .fraction(Constant.halfFraction)
        case .full:
            // `.large` stops at the top safe area, which already carries the
            // floating top bar - so it lands just under the conversation
            // indicator, which is where `full` belongs.
            return .large
        }
    }

    /// Every size, as the set handed to `presentationDetents`.
    static func presentationDetents(
        chromeHeight: CGFloat,
        lastMessageHeight: CGFloat
    ) -> Set<PresentationDetent> {
        Set(
            ascending.map {
                $0.presentationDetent(chromeHeight: chromeHeight, lastMessageHeight: lastMessageHeight)
            }
        )
    }

    /// The size matching a system detent. Unrecognized values resolve to
    /// `collapsed` - the least intrusive answer, and the one the sheet rests
    /// at.
    static func from(
        presentationDetent: PresentationDetent,
        chromeHeight: CGFloat,
        lastMessageHeight: CGFloat
    ) -> ConversationSheetDetent {
        ascending.first {
            $0.presentationDetent(
                chromeHeight: chromeHeight,
                lastMessageHeight: lastMessageHeight
            ) == presentationDetent
        } ?? .collapsed
    }

    /// The largest size at which the Home behind the sheet stays touchable.
    /// Above this the sheet has covered it anyway.
    static var backgroundInteractionCeiling: PresentationDetent {
        .fraction(Constant.halfFraction)
    }

    private enum Constant {
        static let halfFraction: CGFloat = 0.5
        /// Transcript showing above the chrome at `compact`.
        ///
        /// A fixed allowance rather than the last message's measured height: the
        /// measured version has to travel from a UIKit collection view into a
        /// detent, changes as messages arrive, and resizes the sheet under the
        /// reader when it does. This is the one number to change if compact
        /// should show more or less.
        static let compactTranscriptHeight: CGFloat = 96.0
    }
}
