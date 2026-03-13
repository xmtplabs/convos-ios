import ConvosCore
import SwiftUI

struct TypingIndicatorView: View {
    let typers: [ConversationMember]

    private let avatarSize: CGFloat = 24
    private let overlapOffset: CGFloat = 16

    var body: some View {
        HStack(spacing: 8) {
            if !typers.isEmpty {
                avatarStack
            }
            bubble
        }
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("typing-indicator")
    }

    private var avatarStack: some View {
        HStack(spacing: -8) {
            ForEach(Array(typers.prefix(3).enumerated()), id: \.element.id) { index, member in
                AvatarView(
                    fallbackName: member.profile.displayName ?? "",
                    cacheableObject: member.profile,
                    placeholderImage: nil,
                    placeholderImageName: nil,
                    isAgent: member.isAgent
                )
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color(.systemBackground), lineWidth: 2)
                )
                .zIndex(Double(typers.count - index))
            }
        }
    }

    private var bubble: some View {
        MessageContainer(style: .tailed, isOutgoing: false) {
            ZStack {
                Text("")
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12.0)
                    .font(.body)
                PulsingCircleView.typingIndicator
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private var accessibilityText: String {
        switch typers.count {
        case 0:
            return "Someone is typing"
        case 1:
            let name = typers[0].profile.displayName ?? "Someone"
            return "\(name) is typing"
        default:
            return "\(typers.count) people are typing"
        }
    }
}

#Preview("No avatars") {
    TypingIndicatorView(typers: [])
        .padding()
}

#Preview("One typer") {
    TypingIndicatorView(typers: [
        .mock(isCurrentUser: false, name: "Alice")
    ])
    .padding()
}

#Preview("Two typers") {
    TypingIndicatorView(typers: [
        .mock(isCurrentUser: false, name: "Alice"),
        .mock(isCurrentUser: false, name: "Bob")
    ])
    .padding()
}

#Preview("Three typers") {
    TypingIndicatorView(typers: [
        .mock(isCurrentUser: false, name: "Alice"),
        .mock(isCurrentUser: false, name: "Bob"),
        .mock(isCurrentUser: false, name: "Charlie")
    ])
    .padding()
}
