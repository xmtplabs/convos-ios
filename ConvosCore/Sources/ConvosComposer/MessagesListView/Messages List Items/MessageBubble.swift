#if canImport(UIKit)
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
            bubbleText
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .padding(.vertical, 10.0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.displayName): \(message)")
    }

    /// Only messages that actually contain a link pay for the TextKit-backed
    /// `LinkDetectingTextView`; everything else renders as plain `Text`,
    /// which is far cheaper to build and measure when a conversation opens
    /// or scrolls.
    @ViewBuilder
    private var bubbleText: some View {
        if TextLinkPresence.containsLinks(message) {
            LinkDetectingTextView(
                message,
                linkColor: textColor,
                foregroundColor: textColor,
                font: .preferredFont(forTextStyle: .callout)
            )
        } else {
            Text(message)
                .font(.callout)
                .foregroundStyle(textColor)
                .textSelection(.enabled)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.displayName): \(emoji)")
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
#endif
