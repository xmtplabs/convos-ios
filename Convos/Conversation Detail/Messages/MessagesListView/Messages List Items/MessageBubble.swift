import ConvosCore
import SwiftUI

struct MessageBubble: View {
    let style: MessageBubbleType
    let message: String
    let isOutgoing: Bool
    let profile: Profile

    private var textColor: Color {
        if isOutgoing {
            return Color.colorTextPrimaryInverted
        } else {
            return Color.colorTextPrimary
        }
    }

    var body: some View {
        MessageContainer(style: style, isOutgoing: isOutgoing) {
            LinkDetectingTextView(message, linkColor: textColor)
                .foregroundStyle(textColor)
                .font(.callout)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .padding(.vertical, 10.0)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EmojiBubble: View {
    let emoji: String
    let isOutgoing: Bool
    let profile: Profile

    private var textColor: Color {
        if isOutgoing {
            return Color.colorTextPrimaryInverted
        } else {
            return Color.colorTextPrimary
        }
    }

    var body: some View {
        MessageContainer(style: .none, isOutgoing: isOutgoing) {
            Text(emoji)
                .foregroundStyle(textColor)
                .font(.largeTitle.pointSize(64.0))
                .padding(.horizontal, 0.0)
                .padding(.vertical, DesignConstants.Spacing.step2x)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    VStack {
        ForEach([MessageSource.outgoing, MessageSource.incoming], id: \.self) { type in
            MessageBubble(
                style: .normal,
                message: "Hello world!",
                isOutgoing: type == .outgoing,
                profile: .mock(),
            )
            MessageBubble(
                style: .normal,
                message: "Check out https://convos.org for more info",
                isOutgoing: type == .outgoing,
                profile: .mock(),
            )
            MessageBubble(
                style: .tailed,
                message: "Visit www.example.com or email us at hello@example.com",
                isOutgoing: type == .outgoing,
                profile: .mock(),
            )
            EmojiBubble(
                emoji: "❤️❤️❤️",
                isOutgoing: type == .outgoing,
                profile: .mock(),
            )
        }
    }
    .padding(.horizontal, 12.0)
}
