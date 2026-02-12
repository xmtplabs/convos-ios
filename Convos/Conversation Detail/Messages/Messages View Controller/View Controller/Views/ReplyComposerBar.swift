import ConvosCore
import SwiftUI

struct ReplyComposerBar: View {
    let message: AnyMessage
    let onDismiss: () -> Void

    private var senderName: String {
        message.base.sender.profile.displayName
    }

    private var previewText: String {
        switch message.base.content {
        case .text(let text):
            return String(text.prefix(50))
        case .emoji(let emoji):
            return emoji
        default:
            return ""
        }
    }

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            VStack(alignment: .leading, spacing: 2.0) {
                HStack(spacing: 4.0) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(DesignConstants.Fonts.caption3)
                        .foregroundStyle(.colorTextTertiary)
                    Text(senderName)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                }

                Text(previewText)
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
            .accessibilityLabel("Cancel reply")
            .accessibilityIdentifier("cancel-reply-button")
        }
        .padding(.leading, DesignConstants.Spacing.step4x)
        .padding(.trailing, DesignConstants.Spacing.step2x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26.0))
        .padding(.horizontal, 10.0)
        .padding(.bottom, DesignConstants.Spacing.stepHalf)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replying to \(senderName): \(previewText)")
        .accessibilityIdentifier("reply-composer-bar")
    }
}

#Preview("Reply Composer Bar") {
    VStack {
        Spacer()
        ReplyComposerBar(
            message: .message(Message.mock(
                text: "What do you think about the new design?",
                sender: .mock(isCurrentUser: false, name: "Louis"),
                status: .published
            ), .existing),
            onDismiss: {}
        )
    }
}

#Preview("Reply Composer Bar - Long Text") {
    VStack {
        Spacer()
        ReplyComposerBar(
            message: .message(Message.mock(
                text: "I was thinking we could implement a new feature that allows users to customize their profile",
                sender: .mock(isCurrentUser: false, name: "Shane"),
                status: .published
            ), .existing),
            onDismiss: {}
        )
    }
}
