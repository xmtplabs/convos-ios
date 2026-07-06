#if canImport(UIKit)
import SwiftUI

/// Distinct, bordered "Read more" pill (per Quarter's Figma spec): a
/// rounded-rect outline that reads as a tappable button rather than blending
/// into the surrounding text. Shared by the message bubble's long/pathological
/// preview and the thinking thought bubble so both get the same affordance.
///
/// `gesturePassthrough` marks the button so the `.messageGesture` overlay lets
/// the tap through (its `hitTest` returns the overlay unless the point hits a
/// passthrough marker). Message bubbles sit under that overlay and need it; the
/// thought bubble is not wrapped in `.messageGesture`, so it passes `false` and
/// no marker is emitted. The accessibility identifier stays the same in both
/// places since it is the same control.
struct ReadMoreButton: View {
    let action: () -> Void
    let accessibilityHint: String
    let borderColor: Color
    let labelColor: Color
    var gesturePassthrough: Bool = true

    var body: some View {
        let cornerRadius: CGFloat = DesignConstants.CornerRadius.regular
        let horizontalPadding: CGFloat = DesignConstants.Spacing.step4x
        let verticalPadding: CGFloat = DesignConstants.Spacing.step2x
        Button(action: action) {
            Text("Read more")
                .font(DesignConstants.Fonts.buttonText)
                .foregroundStyle(labelColor)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: 1.0)
                )
        }
        .buttonStyle(.plain)
        .accessibilityHint(accessibilityHint)
        .background(passthroughBackground)
        .accessibilityIdentifier("message-read-more-button")
    }

    /// The gesture-passthrough marker, hidden from accessibility so the
    /// representable doesn't surface a second element carrying the button's
    /// identifier. Emitted only where a `.messageGesture` overlay would
    /// otherwise swallow the tap.
    @ViewBuilder
    private var passthroughBackground: some View {
        if gesturePassthrough {
            GesturePassthroughBackground()
                .accessibilityHidden(true)
        }
    }
}
#endif
