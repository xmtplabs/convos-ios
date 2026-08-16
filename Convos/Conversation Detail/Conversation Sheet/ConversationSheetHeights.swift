import CoreGraphics

/// The measurements every sheet size resolves against, gathered so they travel
/// together - each one is meaningless without the others, and passing them
/// separately is how they drift apart.
///
/// All of them are measured above the bottom safe area, which is the form a
/// `.height()` presentation detent wants: the system adds that inset back.
struct ConversationSheetHeights: Equatable {
    /// The collapsed chrome's height - grabber, input bar, tab bar.
    var restingHeight: CGFloat
    /// The chrome plus the whole transcript, capped at the container: the tallest
    /// the sheet will go, so it can never be dragged open onto empty space.
    ///
    /// Defaults to the container so nothing is withheld before the transcript has
    /// measured itself - a sheet capped against a transcript of unknown height
    /// would open barely taller than its own chrome.
    var fittedHeight: CGFloat
    /// The tallest the sheet can be at all.
    var containerHeight: CGFloat

    /// Before anything has been measured. Every size is on offer, which is the
    /// right way to be wrong: the sheet opens as it always did until the
    /// transcript says otherwise.
    static let unmeasured: ConversationSheetHeights = ConversationSheetHeights(
        restingHeight: ConversationSheetMetrics.estimatedRestingHeight,
        fittedHeight: .greatestFiniteMagnitude,
        containerHeight: .greatestFiniteMagnitude
    )
}
