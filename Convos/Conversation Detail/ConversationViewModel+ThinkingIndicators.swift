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
    /// Build-flow special case: when the agent has a thinking session
    /// whose target is a user prompt sent during the build flow, the
    /// descriptor is routed to the contact card group's
    /// `contactCardThinkingDescriptor` instead of an inline footer. That
    /// happens both pre-Make (target prompt still visible but the card is
    /// the canonical anchor) and post-Make (target was filtered out by
    /// `bundledMessageIds`). Gated on `isInAgentBuilderFlow` —
    /// ordinary agent conversations (no builder involvement) skip
    /// this routing and use inline footers exclusively.
    var messagesWithThinkingIndicators: [MessagesListItemType] {
        let base = messagesWithTypingIndicator
        guard !thinkingSessions.isEmpty else { return base }

        let visibleMessageIds: Set<String> = Set(
            base.flatMap { item -> [String] in
                guard case .messages(let group) = item else { return [] }
                return group.allMessages.map(\.messageId)
            }
        )

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
            // The agent's reply to a builder bundle send can target
            // either the text prompt message or the multi-remote
            // attachment message — both client message ids live in
            // `summary.bundledMessageIds`. Route to the contact card
            // whenever the session's target lands inside that set so
            // the indicator never anchors on a now-filtered bundle
            // bubble.
            let targetInBundle: Bool = agentBuilderSummary?.bundledMessageIds
                .contains(session.targetMessageId) ?? false
            // Builder-flow conversations route to the contact card when
            // the target/result aren't visible (filtered out by
            // `bundledMessageIds`) OR while the builder UI is up
            // (pre-Make — the card is the canonical anchor even though
            // the user's prompt is still visible). Ordinary agent
            // conversations skip the card path entirely and use inline
            // footers exclusively, so the indicator surfaces on the
            // actual message bubble the agent is thinking about.
            let shouldRouteToCard: Bool = isInAgentBuilderFlow
                || targetInBundle
                || (!targetVisible && !resultVisible)
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

            if group.agentContactCard != nil,
               let descriptor = contactCardDescriptorsBySender[group.sender.profile.inboxId] {
                updated.contactCardThinkingDescriptor = descriptor
            }

            return .messages(updated)
        }
    }
}
