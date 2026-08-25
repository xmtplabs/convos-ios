#if canImport(UIKit)
import ConvosCore
import SwiftUI
import UIKit

/// The reference card shown above a message that replies to a widget
/// (window.convos.replyToWidget). Mirrors `ReplyReferenceView`'s aesthetic -
/// the turn-up-left glyph over a bordered preview card - but keys off a
/// `ContextReplyContext` (widget title + description) instead of a parent
/// message.
struct ContextReplyReferenceView: View {
    let context: ContextReplyContext
    let isOutgoing: Bool

    var body: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: DesignConstants.Spacing.stepX) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(DesignConstants.Fonts.caption3)
                .foregroundStyle(.tertiary)
                .padding(.leading, isOutgoing ? 0.0 : DesignConstants.Spacing.step3x)
                .padding(.trailing, isOutgoing ? DesignConstants.Spacing.step3x : 0.0)

            HStack(spacing: 0) {
                if isOutgoing {
                    Spacer()
                        .frame(minWidth: 50)
                        .layoutPriority(-1)
                }
                card
                if !isOutgoing {
                    Spacer()
                        .frame(minWidth: 50)
                        .layoutPriority(-1)
                }
            }
        }
        .padding(.top, DesignConstants.Spacing.stepX)
        .padding(.bottom, DesignConstants.Spacing.stepX)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reply to \(context.title): \(context.description)")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 1.0) {
            Text(context.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.colorTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if !context.description.isEmpty {
                Text(context.description)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .frame(maxWidth: 220.0, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Constant.bubbleCornerRadius)
                .strokeBorder(.colorBorderSubtle, lineWidth: 1.0)
        )
    }
}

#Preview("Context Reply - Outgoing") {
    ContextReplyReferenceView(
        context: ContextReplyContext(id: "w1", title: "Weather", description: "Sunny, 24 degrees in San Francisco"),
        isOutgoing: true
    )
    .padding()
}

#Preview("Context Reply - Incoming") {
    ContextReplyReferenceView(
        context: ContextReplyContext(id: "w2", title: "Calendar", description: "Standup at 10am"),
        isOutgoing: false
    )
    .padding()
}
#endif
