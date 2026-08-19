import CoreGraphics
import SwiftUI

/// The handful of numbers the conversation sheet and the capsule share.
///
/// They are stated rather than measured because two parties need the same value
/// and neither contains the other: the capsule floats over the sheet, so the
/// sheet cannot inset itself by measuring it, and the Home behind both has to
/// reserve the same clearance.
enum ConversationSheetMetrics {
    /// The capsule, from the design's own tab bar component (Figma 7893:599).
    ///
    /// That component is a 402x95 bar holding a 180x54 button frame at y=16, with
    /// the capsule background inset -4 around it: 188x62, sitting 21pt above the
    /// bar's bottom edge. The capsule replaces the system bar on this screen, and
    /// the two are on screen together while a push animates, so it has to land in
    /// exactly the same place.
    static let capsuleHeight: CGFloat = 62.0

    /// How far the capsule floats above the screen's *physical* bottom edge - not
    /// the safe area, which is where the system bar sits too.
    static let capsuleBottomInset: CGFloat = 21.0

    /// What the composer keeps clear at its bottom, measured from the sheet's
    /// physical bottom edge: the capsule's own inset, the capsule, and the same
    /// inset again above it.
    ///
    /// The gap above the capsule matches the gap below it deliberately - the
    /// capsule then sits centred in the band between the composer and the screen
    /// edge, rather than crowding one and floating off the other.
    /// What the transcript keeps between its last message and the composer's top
    /// edge.
    ///
    /// The composer floats *over* the transcript here rather than sitting in a row
    /// above it, so nothing separates the two on its own: the clearance the
    /// transcript is handed is the composer's own height, which lands the last
    /// message flush against the bar's top edge. The bar pads its underside by the
    /// same step, so matching it above keeps the composer evenly spaced from what
    /// is on either side of it.
    static let transcriptComposerGap: CGFloat = DesignConstants.Spacing.step2x

    static let composerBottomClearance: CGFloat = capsuleBottomInset
        + capsuleHeight
        + capsuleBottomInset
        - composerIntrinsicBottomPadding

    /// The capsule's inset while the keyboard is up.
    ///
    /// Less than the resting inset, because `keyboardLayoutGuide` tracks the
    /// keyboard's *frame*, and iOS 26's keyboard floats: its frame starts above
    /// the rounded top you can actually see. Measuring the gap from the frame
    /// leaves it reading a dozen points too generous.
    static let capsuleKeyboardBottomInset: CGFloat = capsuleBottomInset - keyboardFrameTopSlack

    /// How far the keyboard's frame sits above its visible top edge.
    private static let keyboardFrameTopSlack: CGFloat = DesignConstants.Spacing.step3x

    /// The composer's clearance while the keyboard is up, shortened by the same
    /// slack the capsule uses so the gap between the two does not change.
    static let composerKeyboardBottomClearance: CGFloat = composerBottomClearance
        - keyboardFrameTopSlack

    /// Transparent space the composer carries below its own visible bar.
    ///
    /// Subtracted above so the gap that *reads* as the spacing matches the one
    /// below the capsule. Measured by eye against the running app rather than
    /// found in the composer's own layout, so it is the first thing to re-check
    /// if that bar's padding ever changes.
    private static let composerIntrinsicBottomPadding: CGFloat = DesignConstants.Spacing.step3x

    /// What the Home reserves at its bottom while the sheet is away - just the
    /// capsule, since that is all that is over it.
    static let homeCapsuleClearance: CGFloat = capsuleHeight + capsuleBottomInset

    /// The sheet's top corners below full screen.
    static let cornerRadius: CGFloat = DesignConstants.CornerRadius.large

    /// Far enough that a tap on the grabber is not read as a one-point drag.
    static let dragMinimumDistance: CGFloat = 2.0

    /// The grabber, and the band it sits in at the sheet's top edge.
    static let grabberSize: CGSize = CGSize(width: 36, height: 5)
    static let grabberAllowance: CGFloat = DesignConstants.Spacing.step4x
}
