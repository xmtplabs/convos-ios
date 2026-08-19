import CoreGraphics
import Foundation
import SwiftUI

/// Resting sizes for the conversation's sheet, smallest first.
///
/// The sheet is a view in the conversation's own hierarchy, not a presentation,
/// so these are plain heights rather than system detents. That is what lets the
/// capsule sit *over* the sheet and outlive it: a presentation renders above
/// everything in the presenting view, so a capsule drawn over the Home would be
/// behind the sheet, and a dismissed sheet would take a capsule of its own with
/// it. Neither is what this design asks for.
///
/// It also retires the whole class of trouble the presentation brought: no set
/// of offered detents to rebuild underneath a live sheet, no selection for the
/// system to re-resolve, and no resize that moves the sheet's origin a layout
/// pass before its height.
enum ConversationSheetDetent: CaseIterable, Comparable {
    /// No sheet at all. The Home has the screen, and the capsule floating over it
    /// is the only conversation control left.
    case collapsed
    /// Half the screen: enough transcript to read an exchange, with the Home
    /// still showing above it.
    case half
    /// The whole screen.
    case full

    static let ascending: [ConversationSheetDetent] = allCases

    /// Whether the sheet is on screen at this size.
    var isPresented: Bool {
        self != .collapsed
    }

    /// Whether the sheet's own surface reaches the top of the screen, where its
    /// rounded corners and its grabber stop being drawn.
    var isFullScreen: Bool {
        self == .full
    }

    /// The system detent this size presents as. `collapsed` has none - it is the
    /// sheet not being presented - so it answers with the smallest real size, for
    /// the selection binding's benefit while the sheet is on its way out.
    var presentationDetent: PresentationDetent {
        switch self {
        case .collapsed, .half: return .fraction(Constant.halfFraction)
        case .full: return .large
        }
    }

    /// The sizes the sheet offers. Fixed, and independent of the transcript and
    /// of the selected lane, so the set is built once and never rebuilt beneath a
    /// live sheet.
    static let presentationDetents: Set<PresentationDetent> = [
        .fraction(Constant.halfFraction),
        .large
    ]

    /// The size matching a system detent, or nil for one it does not describe.
    static func from(presentationDetent: PresentationDetent) -> ConversationSheetDetent? {
        switch presentationDetent {
        case .fraction(Constant.halfFraction): return .half
        case .large: return .full
        default: return nil
        }
    }

    /// The size a conversation opens at.
    ///
    /// Nothing to read means the Home is the point, so the sheet stays away and
    /// leaves it uncovered. Anything unread - or a tap that asked for the agent DM
    /// outright - opens onto the transcript holding it.
    ///
    /// `half`, not `full`: opening a conversation is not a request to be taken to
    /// full screen. The unread message is at the bottom of the transcript, half a
    /// screen shows it and what came before it, and the Home stays in view above.
    static func initial(hasUnread: Bool, agentDmRequested: Bool) -> ConversationSheetDetent {
        hasUnread || agentDmRequested ? .half : .collapsed
    }

    private enum Constant {
        static let halfFraction: CGFloat = 0.5
    }
}
