#if canImport(UIKit)
import SwiftUI

/// The shared look of the composer's floating menus - the participation card and
/// the attachments card. They open from controls sitting next to each other in
/// the same row, so they have to read as one kind of object appearing twice
/// rather than two menus that happen to be neighbours.
enum ComposerMenuMetrics {
    /// The leading icon gutter. Fixed, so every row's title sits on one axis
    /// whatever the glyph's own width.
    static let iconGutter: CGFloat = DesignConstants.Spacing.step8x
    static let iconFont: Font = .system(size: 18.0, weight: .regular)
    static let cardRadius: CGFloat = DesignConstants.CornerRadius.mediumLargest
    /// The card carries only enough side padding for a pressed row's fill to
    /// bleed past the text; the row carries the rest. Together they make the
    /// gutter the text actually sits on.
    static let cardSideInset: CGFloat = DesignConstants.Spacing.step3x
    static let rowSideInset: CGFloat = DesignConstants.Spacing.step3x
    static let rowSpacing: CGFloat = DesignConstants.Spacing.step2x
}

/// Draws the glass card behind a menu's rows, or leaves them bare. A modifier
/// rather than a branch inside each menu's body, so the card's shape is
/// described once and the bodies stay single expressions.
struct ComposerMenuCardSurface: ViewModifier {
    /// False when the host already provides a surface (e.g. inside a sheet), so
    /// the card isn't a card-in-a-card and glass never sits on glass.
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.glassEffect(.regular, in: .rect(cornerRadius: ComposerMenuMetrics.cardRadius))
        } else {
            content
        }
    }
}

/// Fills a row while it is held. A tonal step off the glass rather than a tint
/// laid over it, so the surface itself reads as responding - and the fill spans
/// the card's width the way a picked menu item's does, which is why the row
/// carries the side inset instead of the card.
struct ComposerMenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let fillOpacity: Double = configuration.isPressed ? 0.08 : 0.0
        let radius: CGFloat = DesignConstants.CornerRadius.regular
        configuration.label
            .padding(.horizontal, ComposerMenuMetrics.rowSideInset)
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.colorTextPrimary.opacity(fillOpacity))
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif
