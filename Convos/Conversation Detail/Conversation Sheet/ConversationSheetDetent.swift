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
///
/// Three fixed sizes, and the fixedness is the point. An earlier version had a
/// fourth, `fitted`, whose height was the selected lane's transcript, so that the
/// sheet stopped where the messages did. It cost more than it bought. Its height
/// moved whenever a transcript re-measured, which rebuilt the set of sizes on
/// offer underneath a live sheet; and because each lane had its own, the same
/// detent meant two different heights on the two tabs, so switching tabs resized
/// the sheet without anything asking it to. These three are the same height on
/// both lanes and never move, so the offered set is built once and the only thing
/// that changes the sheet's size is somebody asking it to change.
enum ConversationSheetDetent: CaseIterable, Comparable {
    /// Chrome only - the grabber, the selected tab's bar, and the tab bar.
    /// No transcript. The floating card as it rests today.
    case collapsed
    /// Half the screen: enough transcript to read an exchange, with the Home
    /// still showing above it.
    case compact
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

    /// The smallest size that shows any transcript, for opening the sheet on
    /// something the user asked to read.
    static let smallestReadable: ConversationSheetDetent = .compact

    /// The tallest size, for anything that wants the sheet open as far as it goes.
    static let tallest: ConversationSheetDetent = .full

    /// The size a conversation opens at.
    ///
    /// Nothing to read means the Home is the point, so the sheet rests
    /// collapsed and leaves it uncovered. Anything unread - or a tap that
    /// asked for the agent DM outright - opens onto the transcript holding it,
    /// so a backlog is never hidden behind the Home.
    ///
    /// `compact`, not the ceiling. Opening a conversation is not a request to be
    /// taken to full screen: the unread message is at the bottom of the
    /// transcript, half a screen shows it and what came before it, and the Home
    /// stays in view above. Anyone who wants the rest can drag - which is a
    /// gesture, where arriving at full screen unasked is a surprise.
    static func initial(hasUnread: Bool, agentDmRequested: Bool) -> ConversationSheetDetent {
        hasUnread || agentDmRequested ? .compact : .collapsed
    }
}
