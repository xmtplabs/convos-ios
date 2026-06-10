#if canImport(UIKit)
import Foundation
import UIKit

enum Constant {
    static let maxWidth: CGFloat = 0.75
    static let bubbleCornerRadius: CGFloat = 20.0
    static let minimumPressDurationForReactions: CGFloat = 0.15
    /// Logical width of the largest iPhone screen (Pro Max class).
    private static let largestIPhoneWidth: CGFloat = 440.0
    /// Caps a message bubble row (bubble + its 50pt low-priority spacer) at
    /// the width it would be offered on the largest iPhone screen (its
    /// logical width minus the 16pt trailing row padding). Without this cap,
    /// bubbles and contact cards stretch nearly edge to edge on iPad.
    /// Applied via `View.bubbleRowWidthCap(alignment:)`.
    static let maxBubbleRowWidth: CGFloat = largestIPhoneWidth - 16.0
}
#endif
