import SwiftUI

struct EmojiAvatarView: View {
    let emoji: String

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let fontSize = side * 0.43

            Text(emoji)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .frame(width: side, height: side)
                .background(.colorFillMinimal)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.colorBorderSubtle, lineWidth: 1)
                }
        }
        .aspectRatio(1.0, contentMode: .fit)
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
    }
    .padding()
}
