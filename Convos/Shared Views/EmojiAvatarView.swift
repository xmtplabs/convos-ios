import ConvosCore
import SwiftUI

struct EmojiAvatarView: View {
    let emoji: String
    var agentVerification: AgentVerification = .unverified
    /// When set, the view renders at this exact side length without a
    /// `GeometryReader`. Callers that already know the avatar size (e.g. the
    /// clustered avatar, which lays its sub-avatars out at computed sizes)
    /// pass it so a scrolling list doesn't pay a geometry-feedback pass per
    /// avatar - a clustered cell otherwise nests one `GeometryReader` per
    /// member. Nil keeps the self-sizing path for callers that only constrain
    /// the avatar with an outer `.frame`.
    var size: CGFloat?

    private var background: Color {
        agentVerification.isVerified ? agentVerification.avatarBackgroundColor : .colorFillMinimal
    }

    var body: some View {
        if let size {
            circle(side: size).accessibilityHidden(true)
        } else {
            GeometryReader { geometry in
                circle(side: min(geometry.size.width, geometry.size.height))
            }
            .aspectRatio(1.0, contentMode: .fit)
            .accessibilityHidden(true)
        }
    }

    private func circle(side: CGFloat) -> some View {
        Text(emoji)
            .font(.system(size: side * 0.43, weight: .semibold, design: .rounded))
            .frame(width: side, height: side)
            .background(background)
            .clipShape(Circle())
    }
}

#Preview {
    VStack(spacing: 16) {
        EmojiAvatarView(emoji: "🥫")
            .frame(width: 56, height: 56)
        EmojiAvatarView(emoji: "🦺")
            .frame(width: 56, height: 56)
        EmojiAvatarView(emoji: "🌵")
            .frame(width: 56, height: 56)
        EmojiAvatarView(emoji: "😳")
            .frame(width: 56, height: 56)
        EmojiAvatarView(emoji: "🤖", agentVerification: .verified(.convos))
            .frame(width: 56, height: 56)
        EmojiAvatarView(emoji: "🛂", agentVerification: .verified(.userOAuth))
            .frame(width: 56, height: 56)
    }
    .padding()
}
