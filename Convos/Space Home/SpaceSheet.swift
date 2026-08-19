import ConvosComposer
import ConvosCore
import SwiftUI

/// The convos list, dropped from the Space capsule at the top of the screen.
///
/// Deliberately not a `.sheet`. Two reasons, and the second is the one that
/// settles it: SwiftUI presentation sheets rise from the bottom and cannot be
/// asked to come down from the top; and the Space Home's agent sheet already
/// owns the host's single presentation slot, so a second presented sheet would
/// have to be presented from inside the first. A plain overlay owned by the
/// Space Home is both the shape the design asks for and the one that composes.
///
/// The list inside is `ConversationsViewRepresentable` - the same collection
/// view the app has always shipped, with the same cells, swipe actions,
/// context menus and pagination. Rebuilding it in SwiftUI to put it in a
/// different container would have meant two conversation lists to keep in
/// step, which is exactly one more than anybody wants to own.
struct SpaceSheet: View {
    @Bindable var viewModel: ConversationsViewModel
    /// Every convo, most recent first - the same ordering the strip uses, from
    /// the same source, so the two can't disagree.
    let conversations: [Conversation]
    let spaceTitle: String
    /// Tapping the Space row: back to where you already are, which is what
    /// makes it a way *out* of the list rather than another thing in it.
    let onSelectSpace: () -> Void
    let onSelectConversation: (Conversation) -> Void

    @Binding var conversationPendingExplosion: Conversation?

    var body: some View {
        VStack(spacing: 0) {
            spaceRow
            Divider()
                .padding(.horizontal, DesignConstants.Spacing.step4x)
            list
        }
        .background(Color.colorBackgroundSurfaceless)
        .accessibilityIdentifier("space-sheet")
    }

    /// The way back to the Space. Pinned above the list rather than scrolling
    /// with it: it is the sheet's exit, and an exit that scrolls off is one
    /// you have to scroll back to find.
    private var spaceRow: some View {
        let action = { onSelectSpace() }
        return Button(action: action) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                ZStack {
                    Circle().fill(Color.colorFillMinimal)
                    Image("convosOrangeIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(height: Constant.markHeight)
                }
                .frame(width: Constant.avatarSize, height: Constant.avatarSize)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text(spaceTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.colorTextPrimary)
                    Text("Notes, events and reminders")
                        .font(.callout)
                        .foregroundStyle(.colorTextSecondary)
                }
                .lineLimit(1)

                Spacer(minLength: DesignConstants.Spacing.step2x)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("space-sheet-space-row")
    }

    private var list: some View {
        ConversationsViewRepresentable(
            // One flat run, already ordered. The pinned lane is the list's own
            // ranking and the Space Home does its ranking by recency, so
            // everything arrives as the unpinned section.
            pinnedConversations: [],
            unpinnedConversations: conversations,
            selectedConversationId: viewModel.selectedConversationId,
            isFilteredResultEmpty: viewModel.isFilteredResultEmpty,
            filterEmptyMessage: viewModel.activeFilter.emptyStateMessage,
            hasMoreConversations: viewModel.hasMoreConversations,
            isBootSettled: viewModel.bootSettlement.isSettled,
            onSelectConversation: onSelectConversation,
            onConfirmedDeleteConversation: { viewModel.leave(conversation: $0) },
            onExplodeConversation: { conversationPendingExplosion = $0 },
            onToggleMute: { viewModel.toggleMute(conversation: $0) },
            onToggleReadState: { viewModel.toggleReadState(conversation: $0) },
            onTogglePin: { viewModel.togglePin(conversation: $0) },
            onShowAllFilter: { viewModel.activeFilter = .all },
            onLoadMoreConversations: { viewModel.loadMoreConversationsIfNeeded() }
        )
    }

    private enum Constant {
        static let avatarSize: CGFloat = 56.0
        static let markHeight: CGFloat = 27.0
    }
}
