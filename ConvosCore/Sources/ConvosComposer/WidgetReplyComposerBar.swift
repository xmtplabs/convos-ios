#if canImport(UIKit)
import ConvosCore
import SwiftUI

/// The composer accessory shown while the user is replying to a widget
/// (window.convos.replyToWidget). Mirrors `ReplyComposerBar` - the
/// turn-up-left glyph, a two-line title/preview, and a dismiss button - but
/// keys off a `ContextReplyContext` (widget title + description) instead of a
/// parent message.
public struct WidgetReplyComposerBar: View {
    let context: ContextReplyContext
    let onDismiss: () -> Void

    public init(context: ContextReplyContext, onDismiss: @escaping () -> Void) {
        self.context = context
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            VStack(alignment: .leading, spacing: 2.0) {
                HStack(spacing: 4.0) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(DesignConstants.Fonts.caption3)
                        .foregroundStyle(.colorTextTertiary)
                    Text(context.title)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                }

                Text(context.description)
                    .font(.footnote)
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(1)
            }

            Spacer()

            let action = { onDismiss() }
            Button(action: action) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.colorTextTertiary)
                    .font(.title2)
                    .padding(.horizontal, 3.0)
            }
            .accessibilityLabel("Cancel widget reply")
            .accessibilityIdentifier("cancel-widget-reply-button")
        }
        .padding(.leading, DesignConstants.Spacing.step4x)
        .padding(.trailing, DesignConstants.Spacing.step2x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26.0))
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.bottom, DesignConstants.Spacing.stepHalf)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replying to \(context.title): \(context.description)")
        .accessibilityIdentifier("widget-reply-composer-bar")
    }
}

#Preview("Widget Reply Composer Bar") {
    VStack {
        Spacer()
        WidgetReplyComposerBar(
            context: ContextReplyContext(id: "w1", title: "Weather", description: "Sunny, 24 degrees in San Francisco"),
            onDismiss: {}
        )
    }
}
#endif
