import ConvosCore
import SwiftUI

/// Compact pill that goes in the place of a `LiveBubble` when a member is
/// "present but not currently the active typer" or is "actively typing but
/// hasn't earned the Full slot yet" (because the local user wins on their
/// own device).
///
/// Three dot states:
/// - `.animated` — three pulsing dots, "they're actively typing right now"
/// - `.staticDots` — three dim static dots, "I have text but I'm not active"
/// - `.none` — no dots, just an empty pill (placeholder for "I haven't
///   started typing yet but someone else has")
///
/// Optional avatar to the left for Other-member bubbles (mirrors the
/// `TypingIndicatorView` pattern in the regular conversation list).
struct TypingDotsBubble: View {
    enum DotState {
        case animated
        case staticDots
        case none
    }

    let dotState: DotState
    let avatarMember: ConversationMember?
    let style: LiveBubbleStyle
    let tailCorner: BubbleCorner
    let cornerRadius: CGFloat

    init(
        dotState: DotState,
        avatarMember: ConversationMember? = nil,
        style: LiveBubbleStyle,
        tailCorner: BubbleCorner,
        cornerRadius: CGFloat = Constant.bubbleCornerRadius
    ) {
        self.dotState = dotState
        self.avatarMember = avatarMember
        self.style = style
        self.tailCorner = tailCorner
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step2x) {
            if let avatarMember {
                AvatarView(
                    fallbackName: avatarMember.profile.displayName,
                    cacheableObject: avatarMember.profile,
                    placeholderImage: nil,
                    placeholderImageName: nil,
                    agentVerification: avatarMember.agentVerification
                )
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            }
            pill
        }
    }

    @ViewBuilder
    private var pill: some View {
        ZStack {
            backgroundColor
            dots
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .compositingGroup()
        .mask(maskShape)
    }

    private var backgroundColor: Color {
        switch style {
        case .user:
            return .colorBubble
        case .focusedMember, .otherMember:
            return .colorBubbleIncoming
        }
    }

    private var dotColor: Color {
        switch style {
        case .user:
            return .colorTextPrimaryInverted.opacity(0.7)
        case .focusedMember, .otherMember:
            return .colorTextPrimary.opacity(0.5)
        }
    }

    @ViewBuilder
    private var dots: some View {
        switch dotState {
        case .animated:
            PulsingCircleView(
                configuration: .init(
                    count: 3,
                    size: 8,
                    color: dotColor,
                    spacing: 5,
                    animationDuration: 0.6
                )
            )
        case .staticDots:
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                }
            }
        case .none:
            EmptyView()
        }
    }

    private var maskShape: UnevenRoundedRectangle {
        let small: CGFloat = 4.0
        let big: CGFloat = cornerRadius
        switch tailCorner {
        case .topLeading:
            return .rect(topLeadingRadius: small, bottomLeadingRadius: big, bottomTrailingRadius: big, topTrailingRadius: big)
        case .topTrailing:
            return .rect(topLeadingRadius: big, bottomLeadingRadius: big, bottomTrailingRadius: big, topTrailingRadius: small)
        case .bottomLeading:
            return .rect(topLeadingRadius: big, bottomLeadingRadius: small, bottomTrailingRadius: big, topTrailingRadius: big)
        case .bottomTrailing:
            return .rect(topLeadingRadius: big, bottomLeadingRadius: big, bottomTrailingRadius: small, topTrailingRadius: big)
        }
    }
}

#Preview("animated, with avatar") {
    TypingDotsBubble(
        dotState: .animated,
        avatarMember: ConversationMember(
            profile: .mock(name: "Alice"),
            role: .member,
            isCurrentUser: false
        ),
        style: .otherMember,
        tailCorner: .bottomLeading
    )
    .frame(height: 56)
    .padding()
}

#Preview("static dots, no avatar (me)") {
    TypingDotsBubble(
        dotState: .staticDots,
        avatarMember: nil,
        style: .user,
        tailCorner: .bottomTrailing
    )
    .frame(height: 56)
    .padding()
}

#Preview("empty (me, nothing typed yet)") {
    TypingDotsBubble(
        dotState: .none,
        avatarMember: nil,
        style: .user,
        tailCorner: .bottomTrailing
    )
    .frame(height: 56)
    .padding()
}
