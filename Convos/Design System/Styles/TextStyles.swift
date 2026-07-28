import ConvosComposer
import SwiftUI

enum ConvosTextStyle {
    case display
    case title
    case headline
    case body
    case bodySecondary
    case callout
    case supportingPrimary
    case supporting
    case detail
    case label
    case caption

    var font: Font {
        switch self {
        case .display:
            DesignConstants.Typography.display
        case .title:
            DesignConstants.Typography.title
        case .headline:
            DesignConstants.Typography.headline
        case .body, .bodySecondary:
            DesignConstants.Typography.body
        case .callout:
            DesignConstants.Typography.callout
        case .supportingPrimary, .supporting:
            DesignConstants.Typography.supporting
        case .detail:
            DesignConstants.Typography.detail
        case .label:
            DesignConstants.Typography.label
        case .caption:
            DesignConstants.Typography.caption
        }
    }

    var foregroundColor: Color {
        switch self {
        case .display, .title, .headline, .body, .supportingPrimary:
            .colorTextPrimary
        case .bodySecondary, .callout, .supporting, .detail, .label, .caption:
            .colorTextSecondary
        }
    }

    var tracking: CGFloat {
        switch self {
        case .display:
            Font.convosTitleTracking
        case .title, .headline, .body, .bodySecondary, .callout, .supportingPrimary, .supporting, .detail, .label, .caption:
            0.0
        }
    }
}

private struct ConvosTextStyleModifier: ViewModifier {
    let style: ConvosTextStyle

    func body(content: Content) -> some View {
        content
            .font(style.font)
            .tracking(style.tracking)
            .foregroundStyle(style.foregroundColor)
    }
}

extension View {
    func convosTextStyle(_ style: ConvosTextStyle) -> some View {
        modifier(ConvosTextStyleModifier(style: style))
    }
}
