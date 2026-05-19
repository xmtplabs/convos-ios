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
    ///
    /// Build-flow special case: when the assistant has a thinking session
    /// whose target is a user prompt sent during the build flow, the
    /// descriptor is routed to the contact card group's
    /// `contactCardThinkingDescriptor` instead of an inline footer. That
    /// happens both pre-Make (no summary yet — all user messages are
    /// build-flow) and post-Make (target is no longer visible because the
    /// builder summary's cutoff filtered it out).
    var messagesWithThinkingIndicators: [MessagesListItemType] {
        let base = messagesWithTypingIndicator
        guard !thinkingSessions.isEmpty else { return base }

        let visibleMessageIds: Set<String> = Set(
            base.flatMap { item -> [String] in
                guard case .messages(let group) = item else { return [] }
                return group.allMessages.map(\.messageId)
            }
        )
        let isInBuildFlow: Bool = assistantBuilderSummary == nil

        var descriptorsByMessageId: [String: ThinkingSessionDescriptor] = [:]
        var contactCardDescriptorsBySender: [String: ThinkingSessionDescriptor] = [:]
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

            let targetVisible: Bool = visibleMessageIds.contains(session.targetMessageId)
            let resultVisible: Bool = session.resultMessageId.map { visibleMessageIds.contains($0) } ?? false
            // During the build flow the card is the canonical anchor for
            // any assistant thinking — even though the user's prompt is
            // still visible. Once Make is tapped and the summary's cutoff
            // hides those prompts, the same routing kicks in when the
            // target/result is no longer in the visible set.
            let shouldRouteToCard: Bool = isInBuildFlow || (!targetVisible && !resultVisible)
            if shouldRouteToCard {
                contactCardDescriptorsBySender[session.senderInboxId] = descriptor
                continue
            }

            // Anchor on the target message so "they thought about THIS" shows
            // beneath the originating bubble. When the session resolved with
            // a reply, also anchor on the result so the same indicator
            // surfaces below the reply — the two ends share one descriptor,
            // so tapping either opens the same detail sheet.
            if targetVisible {
                descriptorsByMessageId[session.targetMessageId] = descriptor
            }
            if let resultMessageId = session.resultMessageId, resultVisible {
                descriptorsByMessageId[resultMessageId] = descriptor
            }
        }

        guard !descriptorsByMessageId.isEmpty || !contactCardDescriptorsBySender.isEmpty else {
            return base
        }

        return base.map { item in
            guard case .messages(let group) = item else { return item }
            var updated: MessagesGroup = group

            let messageIds: [String] = group.allMessages.map(\.messageId)
            var attached: [String: ThinkingSessionDescriptor] = [:]
            for messageId in messageIds {
                if let descriptor = descriptorsByMessageId[messageId] {
                    attached[messageId] = descriptor
                }
            }
            if !attached.isEmpty {
                updated.thinkingByMessageId = attached
            }

            if group.assistantContactCard != nil,
               let descriptor = contactCardDescriptorsBySender[group.sender.profile.inboxId] {
                updated.contactCardThinkingDescriptor = descriptor
            }

            return .messages(updated)
        }
    }
}
