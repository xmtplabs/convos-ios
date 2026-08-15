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
    /// The chrome plus the transcript's last message, so the sheet shows the
    /// latest thing said without covering the Home. Its height follows that
    /// message, so it is the one detent whose size is content-driven.
    case compact
    /// Half the screen.
    case half
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
    static func initial(hasUnread: Bool, agentDmRequested: Bool) -> ConversationSheetDetent {
        hasUnread || agentDmRequested ? .full : .collapsed
    }
}
