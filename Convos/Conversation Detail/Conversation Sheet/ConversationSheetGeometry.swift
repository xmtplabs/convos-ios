import Observation
import SwiftUI

/// The sheet's live geometry, for the one thing that needs it every frame: the
/// clearance the Home behind the sheet keeps at its bottom, so the end of a page
/// can always be scrolled out from behind the sheet.
///
/// A reference type read by the Home surfaces themselves rather than a value on
/// the conversation, and that is the whole point of it existing. As
/// `ConversationView` state, a height written on every frame of a drag rebuilt
/// the conversation's body - which re-applied the sheet presentation, rebuilt the
/// sheet's content, re-measured the chrome, and so changed the resting height the
/// detents resolve against while the sheet was still moving. The sheet jumped,
/// driven by the Home's scroll inset. With `@Observable`, only the views that
/// read these properties update when they change, and the conversation is not one
/// of them.
@MainActor
@Observable
final class ConversationSheetGeometry {
    /// How much of the screen the sheet occupies right now, measured from the
    /// physical bottom edge - which is how much of the Home it covers.
    var coveredHeight: CGFloat = ConversationSheetMetrics.homeCapsuleClearance
    /// The tallest the sheet can be, in the same convention. Zero until measured.
    var containerHeight: CGFloat = 0
    /// Whether the sheet is on screen at all. With it away the Home reserves only
    /// the capsule's clearance, whatever the sheet last reported.
    var isSheetPresented: Bool = false
    /// What is over the Home when the sheet is away: the capsule, and the gap
    /// below it. The Home never reserves less than this.
    var restingHeight: CGFloat = ConversationSheetMetrics.homeCapsuleClearance

    /// What the Home keeps clear at its bottom.
    ///
    /// Bounded at both ends, and neither bound is a fraction of anything. Below,
    /// the resting height: the sheet is never shorter than collapsed. Above, the
    /// full height the sheet can occupy - past that it has covered the Home
    /// outright, and there is no inset to see or scroll against.
    ///
    /// Both bounds are measured the same way `coveredHeight` is. A ceiling taken
    /// as a fraction of some other view's height is not comparable to this one,
    /// and the gap between the two conventions showed up as a page that stopped
    /// a few points short of the sheet's edge.
    var homeBottomClearance: CGFloat {
        // The sheet's presence decides this, not its last reported height. A
        // dismissal reports on its way out, and relying on those reports to stop
        // arriving left the Home holding half a screen for a sheet that was gone.
        guard isSheetPresented else { return restingHeight }
        let covered: CGFloat = max(coveredHeight, restingHeight)
        guard containerHeight > 0 else { return covered }
        return min(covered, max(containerHeight, restingHeight))
    }
}
