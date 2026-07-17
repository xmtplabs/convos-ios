import Foundation

extension Contact {
    /// Returns a copy representing the agent **template** rather than this
    /// running instance: the canonical published name + emoji (stable
    /// across instances) overlaid, the per-instance encrypted avatar
    /// cleared so the canonical emoji renders as the avatar. Identity and
    /// agent fields (inboxId, verification, templateId, publishedUrl) are
    /// kept from the representative instance so selection, verification
    /// chrome, Share, and spawn-by-template all keep working.
    ///
    /// The canonical avatar URL (`info.avatarURL`) is intentionally not used
    /// yet - the avatar pipeline expects per-conversation encrypted material,
    /// so rendering a plain template image URL is a follow-up. Until then the
    /// canonical emoji is the stable visual.
    func mergingCanonicalTemplate(_ info: AgentTemplateInfo, isBlocked: Bool) -> Contact {
        Contact(
            inboxId: inboxId,
            displayName: info.agentName ?? displayName,
            avatarURL: nil,
            avatarSalt: nil,
            avatarNonce: nil,
            avatarKey: nil,
            addedAt: addedAt,
            addedViaConversationId: addedViaConversationId,
            isBlocked: isBlocked,
            agentVerification: agentVerification,
            agentTemplateId: info.templateId,
            agentTemplatePublishedURL: info.publishedURL ?? agentTemplatePublishedURL,
            profileEmoji: info.emoji ?? profileEmoji,
            agentInstanceId: agentInstanceId,
            agentAttestation: agentAttestation
        )
    }

    /// Copy with `isBlocked` overridden. Used by the dedup so a collapsed
    /// agent row reflects a block on any of its running instances.
    func withBlocked(_ blocked: Bool) -> Contact {
        Contact(
            inboxId: inboxId,
            displayName: displayName,
            avatarURL: avatarURL,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce,
            avatarKey: avatarKey,
            addedAt: addedAt,
            addedViaConversationId: addedViaConversationId,
            isBlocked: blocked,
            agentVerification: agentVerification,
            agentTemplateId: agentTemplateId,
            agentTemplatePublishedURL: agentTemplatePublishedURL,
            profileEmoji: profileEmoji,
            agentInstanceId: agentInstanceId,
            agentAttestation: agentAttestation
        )
    }
}

extension Array where Element == Contact {
    /// Collapses template-backed agents to a single representative per
    /// `agentTemplateId` (the first encountered), overlaying the cached
    /// canonical template identity when available; humans and template-less
    /// contacts pass through untouched. Order is preserved. When the cache
    /// is still cold for a template, its representative shows instance data
    /// until the canonical identity arrives.
    func dedupingAgentsByTemplate(using templates: [String: AgentTemplateInfo]) -> [Contact] {
        // A block on ANY instance of a template blocks the canonical row, so
        // collapsing instances can never hide a block the user made.
        var blockedTemplateIds: Set<String> = []
        for contact in self where contact.isBlocked {
            if let templateId = contact.agentTemplateId {
                blockedTemplateIds.insert(templateId)
            }
        }
        var result: [Contact] = []
        var seenTemplateIds: Set<String> = []
        for contact in self {
            guard let templateId = contact.agentTemplateId else {
                result.append(contact)
                continue
            }
            guard seenTemplateIds.insert(templateId).inserted else { continue }
            let blocked = blockedTemplateIds.contains(templateId)
            if let info = templates[templateId] {
                result.append(contact.mergingCanonicalTemplate(info, isBlocked: blocked))
            } else {
                result.append(contact.withBlocked(blocked))
            }
        }
        return result
    }
}
