import SwiftUI

enum ConvosSurfaceStyle {
    case screen
    case raised
    case raisedSecondary
    case card
    case subtle
    case emptyState
    case inverted

    var backgroundColor: Color {
        switch self {
        case .screen:
            .colorBackgroundSurfaceless
        case .raised, .card:
            .colorBackgroundRaised
        case .raisedSecondary:
            .colorBackgroundRaisedSecondary
        case .subtle, .emptyState:
            .colorFillMinimal
        case .inverted:
            .colorBackgroundInverted
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .screen:
            0.0
        case .raised, .raisedSecondary:
            DesignConstants.CornerRadius.medium
        case .card:
            DesignConstants.CornerRadius.mediumLarge
        case .subtle:
            DesignConstants.CornerRadius.regular
        case .emptyState:
            DesignConstants.CornerRadius.mediumLarge
        case .inverted:
            DesignConstants.CornerRadius.medium
        }
    }

    var borderColor: Color? {
        switch self {
        case .card:
            .colorBorderSubtle
        case .screen, .raised, .raisedSecondary, .subtle, .emptyState, .inverted:
            nil
        }
    }
}

private struct ConvosSurfaceModifier: ViewModifier {
    let style: ConvosSurfaceStyle
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(style.backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
            .overlay {
                if let borderColor = style.borderColor {
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .stroke(borderColor, lineWidth: DesignConstants.Layout.hairline)
                }
            }
    }
}

extension View {
    func convosSurface(
        _ style: ConvosSurfaceStyle,
        padding: CGFloat = 0.0
    ) -> some View {
        modifier(ConvosSurfaceModifier(style: style, padding: padding))
    }
}
