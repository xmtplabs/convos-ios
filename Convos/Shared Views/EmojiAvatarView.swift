import ConvosCore
import SwiftUI

struct EmojiAvatarView: View {
    let emoji: String
    var agentVerification: AgentVerification = .unverified

    private var background: Color {
        agentVerification.isVerified ? agentVerification.avatarBackgroundColor : .colorFillMinimal
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let fontSize = side * 0.43

            Text(emoji)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .frame(width: side, height: side)
                .background(background)
                .clipShape(Circle())
        }
        .aspectRatio(1.0, contentMode: .fit)
        .accessibilityHidden(true)
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
