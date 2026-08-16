import CoreGraphics
import Foundation

/// Resting sizes for the conversation's floating sheet, smallest first. The
/// sheet holds the selected transcript above its composer and tab bar, and the
/// detent decides how much of that transcript is showing; the Home surface is
/// always behind it.
///
/// These map onto system presentation detents - see
/// `ConversationSheetPresentationDetents` - so the sheet is a real `.sheet`
/// and the system owns the drag and the physics.
enum ConversationSheetDetent: CaseIterable, Comparable {
    /// Chrome only - the grabber, the selected tab's bar, and the tab bar.
    /// No transcript. The floating card as it rests today.
    case collapsed
    /// Half the screen: enough transcript to read an exchange, with the Home
    /// still showing above it.
    ///
    /// A stop on the way rather than a ceiling, and only offered when it is
    /// meaningfully below `fitted` - otherwise it is a second name for the same
    /// height and catches a drag for no reason.
    case compact
    /// As tall as there is transcript to show, and no taller.
    ///
    /// The ceiling. Its height is the chrome plus the messages, so a conversation
    /// with two messages in it stops just past them instead of opening onto most
    /// of a screen of nothing. Once the transcript reaches the container this is
    /// `full` in all but name, and `full` is offered in its place.
    case fitted
    /// Everything up to just below the conversation indicator.
    case full

    /// Ordered smallest to largest, which `Comparable` follows.
    static let ascending: [ConversationSheetDetent] = allCases

    /// Whether the sheet shows transcript content at this size. `collapsed`
    /// is the only one that does not, which is what lets the Home own the
    /// whole screen behind it.
    var showsTranscript: Bool {
        self != .collapsed
    }

    /// The size a conversation opens at.
    ///
    /// Nothing to read means the Home is the point, so the sheet rests
    /// collapsed and leaves it uncovered. Anything unread - or a tap that
    /// asked for the agent DM outright - opens onto the transcript holding it,
    /// so a backlog is never hidden behind the Home.
    ///
    /// `fitted` rather than `full`: it is as much transcript as there is, which is
    /// the whole screen for a long conversation and only a little card for a short
    /// one. Opening at `full` regardless would land a two-message conversation on
    /// mostly empty space.
    static func initial(hasUnread: Bool, agentDmRequested: Bool) -> ConversationSheetDetent {
        hasUnread || agentDmRequested ? .fitted : .collapsed
    }
}
