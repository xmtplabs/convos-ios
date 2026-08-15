import SwiftUI

/// Bridges `ConversationSheetDetent` onto the system's presentation detents so
/// the conversation sheet is a real `.sheet`: the system owns the drag, the
/// physics, the content-drag-to-resize handoff and the background
/// pass-through, and these types only answer "how tall is this one".
///
/// Two of the four heights are content-driven, and a `CustomPresentationDetent`
/// only sees its `Context`. `Context` reads the environment, so the measured
/// chrome and last-message heights are published there (see
/// `conversationSheetChromeHeight`) rather than threaded through a binding.

/// `collapsed`: the card's chrome and nothing else - grabber, bar, tab bar -
/// leaving the Home uncovered.
struct CollapsedSheetDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        ConversationSheetDetentHeights.collapsed(
            chrome: context.conversationSheetChromeHeight,
            maxDetent: context.maxDetentValue
        )
    }
}

/// `compact`: the chrome plus the transcript's last message, so the latest
/// thing said is visible without covering the Home. Collapses onto the chrome
/// height until the transcript reports a message, rather than opening a blank
/// gap above the composer.
struct CompactSheetDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        ConversationSheetDetentHeights.compact(
            chrome: context.conversationSheetChromeHeight,
            lastMessage: context.conversationSheetLastMessageHeight,
            maxDetent: context.maxDetentValue
        )
    }
}

/// `full`: everything up to just below the conversation indicator.
/// `maxDetentValue` already stops at the safe area, so this only backs off the
/// gap beneath the floating top bar.
struct FullSheetDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        ConversationSheetDetentHeights.full(
            chrome: context.conversationSheetChromeHeight,
            maxDetent: context.maxDetentValue,
            topGap: Constant.topGap
        )
    }

    private enum Constant {
        /// Breathing room between the conversation indicator and the card's
        /// top edge. `maxDetentValue` already stops at the safe area, which
        /// carries the floating top bar itself.
        static let topGap: CGFloat = 8.0
    }
}

extension ConversationSheetDetent {
    /// The system detent this size presents as.
    var presentationDetent: PresentationDetent {
        switch self {
        case .collapsed: .custom(CollapsedSheetDetent.self)
        case .compact: .custom(CompactSheetDetent.self)
        case .half: .fraction(Constant.halfFraction)
        case .full: .custom(FullSheetDetent.self)
        }
    }

    /// The sizes to offer, as the set handed to `presentationDetents`.
    ///
    /// `compact` is withheld until the transcript has reported a message to
    /// size it to. Without one it resolves to exactly the `collapsed` height,
    /// and two detents at the same height are indistinguishable to a drag: the
    /// system settles on either, and landing on `compact` shows the transcript
    /// at what looks like the collapsed size.
    static func presentationDetents(lastMessageHeight: CGFloat) -> Set<PresentationDetent> {
        let offered: [ConversationSheetDetent] = ascending.filter {
            $0 != .compact || lastMessageHeight > 0
        }
        return Set(offered.map(\.presentationDetent))
    }

    /// The size matching a system detent, for reading the selection back.
    /// Unrecognized values resolve to `collapsed` - the least intrusive
    /// answer, and the one the sheet rests at.
    init(presentationDetent: PresentationDetent) {
        self = Self.ascending.first { $0.presentationDetent == presentationDetent } ?? .collapsed
    }

    /// The largest size at which the Home behind the sheet stays touchable.
    /// Above this the sheet has covered it anyway.
    static var backgroundInteractionCeiling: PresentationDetent {
        ConversationSheetDetent.half.presentationDetent
    }

    private enum Constant {
        static let halfFraction: CGFloat = 0.5
    }
}

// MARK: - Measured content, published for the detents to read

private struct ConversationSheetChromeHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = ConversationSheetMetrics.estimatedCollapsedHeight
}

private struct ConversationSheetLastMessageHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Measured height of the sheet's chrome - grabber, bar, tab bar - which
    /// is the `collapsed` height and the floor for every other detent.
    var conversationSheetChromeHeight: CGFloat {
        get { self[ConversationSheetChromeHeightKey.self] }
        set { self[ConversationSheetChromeHeightKey.self] = newValue }
    }

    /// Measured height of the selected transcript's last message, which is
    /// what `compact` sizes itself to.
    var conversationSheetLastMessageHeight: CGFloat {
        get { self[ConversationSheetLastMessageHeightKey.self] }
        set { self[ConversationSheetLastMessageHeightKey.self] = newValue }
    }
}
