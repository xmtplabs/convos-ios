import SwiftUI

struct MessageContainer<Content: View>: View {
    let style: MessageBubbleType
    let isOutgoing: Bool
    let cornerRadius: CGFloat = Constant.bubbleCornerRadius
    @ViewBuilder let content: () -> Content

    var spacer: some View {
        Spacer()
            .frame(minWidth: 50.0)
            .layoutPriority(-1)
    }

    var mask: UnevenRoundedRectangle {
        switch style {
        case .normal:
            return .rect(
                topLeadingRadius: cornerRadius,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius,
                topTrailingRadius: cornerRadius
            )
        case .tailed:
            if isOutgoing {
                return .rect(
                    topLeadingRadius: cornerRadius,
                    bottomLeadingRadius: cornerRadius,
                    bottomTrailingRadius: 2.0,
                    topTrailingRadius: cornerRadius
                )
            } else {
                return .rect(
                    topLeadingRadius: cornerRadius,
                    bottomLeadingRadius: 2.0,
                    bottomTrailingRadius: cornerRadius,
                    topTrailingRadius: cornerRadius
                )
            }
        case .none:
            return .rect(cornerRadii: .init())
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0.0) {
            if isOutgoing {
                spacer
            }

            switch style {
            case .none:
                content()
                    .foregroundColor(isOutgoing ? .colorTextPrimaryInverted : .colorTextPrimary)
            default:
                content()
                    .background(isOutgoing ? Color.colorBubble : Color.colorBubbleIncoming)
                    .foregroundColor(isOutgoing ? .colorTextPrimaryInverted : .colorTextPrimary)
                    .compositingGroup()
                    .mask(mask)
            }

            if !isOutgoing {
                spacer
            }
        }
    }
}
