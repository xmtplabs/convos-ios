import ConvosCore
import Foundation

/// Builds the `[MessagesListItemType]` snapshot rendered inside
/// `ThinkingDetailView`'s `MessagesViewController`. Parallels
/// `MessagesListProcessor` for the regular chat — instead of grouping
/// arbitrary conversation messages, it folds every `start` moment in a
/// thinking session into a single `MessagesGroup` keyed by the agent, so
/// `MessagesGroupView` handles avatar, tail, spacing, and sender-label
/// suppression naturally.
///
/// When the session is still active (no `resultMessageId`), the group is
/// marked with `showsThinkingIndicator = true` so `MessagesGroupView`
/// renders the pulsing-dot bubble as its trailing item and attaches the
/// agent avatar to it — the same affordance the inline footer surfaces.
enum ThinkingDetailListProcessor {
    static func process(_ descriptor: ThinkingSessionDescriptor) -> [MessagesListItemType] {
        let starts = descriptor.moments.filter { $0.state == .start }
        let lastStartId: String? = starts.last?.id

        let messages: [AnyMessage] = starts.map { moment in
            let message = Message(
                id: moment.id,
                sender: descriptor.sender,
                source: .incoming,
                status: .published,
                content: .text(moment.content),
                date: moment.sentAt,
                reactions: []
            )
            // Mark the newest moment as `.inserted` so SwiftUI's group-level
            // appearance transition (`opacity + scale`) runs when a new
            // moment arrives, matching how regular chat animates a fresh
            // message into an existing run.
            let origin: AnyMessage.Origin = moment.id == lastStartId ? .inserted : .existing
            return .message(message, origin)
        }

        let showsBubble: Bool = descriptor.isActive
        var items: [MessagesListItemType] = []
        if !messages.isEmpty || showsBubble {
            var group = MessagesGroup(
                id: "thinking-detail-\(descriptor.id)",
                sender: descriptor.sender,
                messages: messages,
                isLastGroup: false,
                isLastGroupSentByCurrentUser: false
            )
            group.hidesSenderLabel = true
            group.showsThinkingIndicator = showsBubble
            group.usesThoughtBubbleStyle = true
            items.append(.messages(group))
        }
        return items
    }
}
