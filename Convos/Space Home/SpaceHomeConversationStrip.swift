import ConvosComposer
import ConvosCore
import SwiftUI

/// Every convo, most recent first, as a horizontal run of avatars across the
/// top of the Space Home.
///
/// Not the pinned row. Pinning ranks a handful of convos above a list that
/// holds the rest; the strip is the whole list, laid sideways, and ordered by
/// the only thing that reliably predicts what you want next - what just
/// happened. `lastActivityDate` is the same key the conversations list sorts
/// on, so the strip and the sheet dropped from the Space capsule can never
/// disagree about what "most recent" means.
///
/// The tiles are `PinnedConversationItem` unchanged: a 96pt avatar, the unread
/// preview bubble above it, and the name with its unread dot or mute bell
/// below. It was already the right component - it was only ever called "pinned"
/// because pinning is where it first appeared.
struct SpaceHomeConversationStrip: View {
    let conversations: [Conversation]
    let onSelect: (Conversation) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: DesignConstants.Spacing.step6x) {
                ForEach(conversations) { conversation in
                    tile(for: conversation)
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step6x)
            .padding(.top, DesignConstants.Spacing.step5x)
            .padding(.bottom, DesignConstants.Spacing.step2x)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("space-home-conversation-strip")
    }

    @ViewBuilder
    private func tile(for conversation: Conversation) -> some View {
        let selectAction = { onSelect(conversation) }
        PinnedConversationItem(conversation: conversation)
            // The item sizes itself to `maxWidth: .infinity`, which inside a
            // horizontal stack means "as wide as my content" - the preview
            // bubble, which is wider than the avatar. Pinning the frame to the
            // avatar keeps the spacing even whether or not a tile is showing
            // a preview.
            .frame(width: Constant.tileWidth)
            .contentShape(.rect)
            .onTapGesture(perform: selectAction)
            .id(conversation.id)
    }

    private enum Constant {
        /// Matches `PinnedConversationItem`'s default avatar size.
        static let tileWidth: CGFloat = 96.0
    }
}

#Preview {
    SpaceHomeConversationStrip(
        conversations: [
            .mock(id: "1", name: "Saturday thing", isUnread: true, lastMessageText: "told everyone 8:30"),
            .mock(id: "2", name: "NYC June 2025", isUnread: true, lastMessageText: "three options on the board"),
            .mock(id: "3", name: "Goonies Soccer", isMuted: true),
            .mock(id: "4", name: "Convo 84B"),
            .mock(id: "5", name: "darick@bluesky.social"),
            .mock(id: "6", name: "Project Team")
        ],
        onSelect: { _ in }
    )
    .background(Color.colorBackgroundSurfaceless)
}
