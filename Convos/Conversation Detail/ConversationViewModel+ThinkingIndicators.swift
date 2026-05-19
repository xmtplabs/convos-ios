import Combine
import ConvosCore
import Foundation

/// Maps active `convos.org/thinking:1.0` sessions onto the messages list as
/// inline footers anchored to their `targetMessageId`. The renderer (a
/// read-receipt-style row under the target bubble) lives in
/// `MessagesGroupView`; the standalone bubble is only used by
/// `ThinkingDetailView` from here on.
extension ConversationViewModel {
    /// `messagesWithTypingIndicator` with each group's `thinkingByMessageId`
    /// populated from the active session feed. Sessions whose sender isn't a
    /// current member (agent left mid-thought) or whose target message
    /// isn't yet in the visible list are dropped — the indicator only shows
    /// once both anchors exist.
    var messagesWithThinkingIndicators: [MessagesListItemType] {
        let base = messagesWithTypingIndicator
        guard !thinkingSessions.isEmpty else { return base }

        var descriptorsByMessageId: [String: ThinkingSessionDescriptor] = [:]
        for session in thinkingSessions {
            guard let member = conversation.members.first(where: { $0.profile.inboxId == session.senderInboxId }) else {
                continue
            }
            // Drop terminated sessions that never produced a reply — a
            // `stop` without `resultMessageId` is the agent's cancel
            // signal, so the inline footer shouldn't keep anchoring on a
            // target the user can't navigate from. The detail sheet still
            // surfaces them via `ThinkingSessionRepository`, which keeps
            // every session.
            if !session.isActive && session.resultMessageId == nil {
                continue
            }
            let descriptor = ThinkingSessionDescriptor(
                id: session.id,
                sender: member,
                targetMessageId: session.targetMessageId,
                moments: session.moments,
                resultMessageId: session.resultMessageId,
                isActive: session.isActive
            )
            // Anchor on the target message so "they thought about THIS" shows
            // beneath the originating bubble. When the session resolved with
            // a reply, also anchor on the result so the same indicator
            // surfaces below the reply — the two ends share one descriptor,
            // so tapping either opens the same detail sheet.
            descriptorsByMessageId[session.targetMessageId] = descriptor
            if let resultMessageId = session.resultMessageId {
                descriptorsByMessageId[resultMessageId] = descriptor
            }
        }

        guard !descriptorsByMessageId.isEmpty else { return base }

        return base.map { item in
            guard case .messages(let group) = item else { return item }
            let messageIds: [String] = group.allMessages.map(\.messageId)
            var attached: [String: ThinkingSessionDescriptor] = [:]
            for messageId in messageIds {
                if let descriptor = descriptorsByMessageId[messageId] {
                    attached[messageId] = descriptor
                }
            }
            guard !attached.isEmpty else { return item }
            var updated = group
            updated.thinkingByMessageId = attached
            return .messages(updated)
        }
    }
}
