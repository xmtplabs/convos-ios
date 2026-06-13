import ConvosCore
import SwiftUI

/// Cycles through mock conversations in the chats-tab empty state using a
/// larger version of [[PinnedConversationItem]]. Each mock plays in
/// phases: the conversation appears read, an unread message then animates
/// in (preview bubble plus unread dot), holds, and the carousel
/// crossfades to the next mock.
struct EmptyStateMockConversationCarousel: View {
    let mocks: [EmptyStateMockConversation]

    @State private var index: Int = 0
    @State private var showsUnread: Bool = false

    private var currentMock: EmptyStateMockConversation? {
        guard !mocks.isEmpty else { return nil }
        return mocks[index % mocks.count]
    }

    var body: some View {
        ZStack {
            if let mock = currentMock {
                PinnedConversationItem(
                    conversation: conversation(for: mock),
                    avatarSize: Constant.avatarSize,
                    messagePreviewWidth: Constant.messagePreviewWidth
                )
                .id(mock.id)
                .transition(.blurReplace)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
        .task(id: mocks) {
            await cycle()
        }
    }

    private func conversation(for mock: EmptyStateMockConversation) -> Conversation {
        .emptyStateMock(
            id: mock.id,
            name: mock.name,
            emoji: mock.emoji,
            isUnread: showsUnread,
            lastMessageText: mock.messageText
        )
    }

    /// Loops the phase animation until the view disappears (the `.task`
    /// cancels the loop) or the mock list changes (the `id:` restarts it).
    private func cycle() async {
        guard !mocks.isEmpty else { return }
        index = 0
        showsUnread = false
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(Constant.readPhaseDuration))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    showsUnread = true
                }
                try await Task.sleep(for: .seconds(Constant.unreadPhaseDuration))
                withAnimation(.smooth(duration: 0.35)) {
                    showsUnread = false
                    index += 1
                }
            } catch {
                return
            }
        }
    }

    private enum Constant {
        static let avatarSize: CGFloat = 120.0
        static let messagePreviewWidth: CGFloat = 220.0
        static let readPhaseDuration: TimeInterval = 1.0
        static let unreadPhaseDuration: TimeInterval = 2.8
    }
}

#Preview {
    EmptyStateMockConversationCarousel(mocks: [
        EmptyStateMockConversation(
            id: "soccer",
            name: "Dunes Soccer Club",
            emoji: "⚽️",
            messageText: "Skipper: need 3 more RSVPs for tomorrow's match"
        ),
        EmptyStateMockConversation(
            id: "fam",
            name: "Fam",
            emoji: "🏡",
            messageText: "Mealplanner: this week's dinner plan is ready"
        ),
    ])
    .frame(height: 200)
}
