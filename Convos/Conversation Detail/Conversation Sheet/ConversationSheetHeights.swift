import CoreGraphics

/// The measurements the sheet's sizes resolve against.
///
/// Measured above the bottom safe area, which is the form a `.height()`
/// presentation detent wants: the system adds that inset back.
struct ConversationSheetHeights: Equatable {
    /// The collapsed chrome's height - grabber, input bar, tab bar. The only
    /// measurement any size depends on, now that the sheet's sizes are fixed
    /// fractions of the screen rather than a function of the transcript.
    var restingHeight: CGFloat

    /// Before the chrome has measured itself.
    static let unmeasured: ConversationSheetHeights = ConversationSheetHeights(
        restingHeight: ConversationSheetMetrics.estimatedRestingHeight
    )
}
