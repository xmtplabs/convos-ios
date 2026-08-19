import Foundation

/// Finds - and the first time, provisions - the user's personal Space: the
/// conversation the Space Home renders, holding their notes, events and
/// reminders.
///
/// The Space is an ordinary conversation wearing three constraints:
///
/// - **Two members**, the user and their own agent. The agent comes free:
///   every conversation in the warm cache has a default agent added while it
///   is still hidden, so claiming one claims an agent with it.
/// - **Locked**, so nobody can be invited. `lockConversation` sets the group's
///   add-member policy to `deny`, which is the same lock the UI offers
///   elsewhere - the Space is not a special case the permission system has to
///   learn about.
/// - **Origin-less**, which is what makes it findable. Every other agent DM is
///   a satellite of the group it was started from and records that parent in
///   `agent_dm_origin`; the Space is started from nothing and records no
///   parent. See `ConversationsRepositoryProtocol.findPersonalSpace`.
///
/// That last one is why no new marker had to be invented. An origin-less agent
/// DM is already excluded from the conversations list (the list filters agent
/// DMs out) and already folds into no group's row (folding is driven by the
/// origin link it doesn't have). The Space is therefore invisible everywhere a
/// conversation would normally appear, without a single query being taught
/// about it - which is exactly right, because it is not a conversation in the
/// list. It is the screen the list sits on top of.
public actor PersonalSpaceService {
    private let session: any SessionManagerProtocol
    /// One provision at a time. Two callers arriving together (the Space Home
    /// appearing while a push wakes the app) would otherwise each claim a
    /// different pooled conversation and mark both as the Space, and
    /// `findPersonalSpace` would start returning whichever the ordering
    /// happened to favour.
    private var provisionTask: Task<Conversation, Error>?

    public init(session: any SessionManagerProtocol) {
        self.session = session
    }

    /// The user's Space, provisioning one if this is the first time it has
    /// been asked for. Safe to call on every appearance of the Space Home:
    /// the common path is a single indexed read.
    public func personalSpace() async throws -> Conversation {
        if let existing = try findExisting() {
            return existing
        }
        if let provisionTask {
            return try await provisionTask.value
        }
        let task = Task<Conversation, Error> { [weak self] in
            guard let self else { throw PersonalSpaceError.provisioningUnavailable }
            return try await self.provision()
        }
        provisionTask = task
        defer { provisionTask = nil }
        return try await task.value
    }

    /// The Space as it stands, without provisioning one. For callers that want
    /// to render something the moment they have it and are content to show
    /// nothing until it exists.
    public nonisolated func existingPersonalSpace() -> Conversation? {
        try? session.conversationsRepository(for: Self.consentScope).findPersonalSpace()
    }

    private func findExisting() throws -> Conversation? {
        try session.conversationsRepository(for: Self.consentScope).findPersonalSpace()
    }

    private func provision() async throws -> Conversation {
        // Re-check inside the task: a provision that completed while this one
        // was queued behind it has already made the Space.
        if let existing = try findExisting() {
            return existing
        }

        let (_, claimedId) = await session.prepareNewConversation()
        guard let conversationId = claimedId else {
            throw PersonalSpaceError.noPooledConversation
        }

        // Commit before marking. The markers are written against the XMTP
        // group, and a row still flagged unused is one the user cannot see if
        // anything below fails - better a visible conversation missing its
        // lock than an invisible one holding the Space's identity.
        await session.commitClaimedConversation(id: conversationId)

        // The agent-DM marker only sticks to a conversation that already has
        // its agent: `isAgentDm` is re-derived on every save as "marker AND two
        // members AND one of them a verified agent", so marking an empty
        // conversation writes a flag the next sync erases.
        await session.ensureDefaultAgentConversationReady(id: conversationId)
        try await awaitAgentMember(in: conversationId)

        let metadataWriter = session.messagingService().conversationMetadataWriter()
        try await metadataWriter.markAsAgentDm(conversationId, originConversationId: nil)
        try await metadataWriter.lockConversation(for: conversationId)

        guard let space = try findExisting() else {
            throw PersonalSpaceError.provisionedButNotFound(conversationId: conversationId)
        }
        Log.info("Personal Space provisioned: \(conversationId)")
        return space
    }

    /// Waits for the agent to show up in the local member list.
    ///
    /// `ensureDefaultAgentConversationReady` returns when the join has landed
    /// server-side, which is a different moment from the member row existing
    /// on this device - that arrives over sync. Polling rather than observing
    /// because this runs once in a conversation's life and the observation
    /// plumbing would outlive its usefulness by a long way.
    private func awaitAgentMember(in conversationId: String) async throws {
        let repository = session.conversationsRepository(for: Self.consentScope)
        for attempt in 0..<Self.agentPollAttempts {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(Self.agentPollIntervalMilliseconds))
            }
            let conversation = try await repository.fetchAll().first { $0.id == conversationId }
            if conversation?.members.contains(where: \.isVerifiedAgent) == true {
                return
            }
        }
        throw PersonalSpaceError.agentNeverArrived(conversationId: conversationId)
    }

    private static let consentScope: [Consent] = [.allowed, .unknown]
    private static let agentPollAttempts: Int = 20
    private static let agentPollIntervalMilliseconds: Int = 500
}

// MARK: - Errors

public enum PersonalSpaceError: Error, Equatable {
    /// The warm cache had nothing to claim. Transient: the pool refills.
    case noPooledConversation
    /// The agent never joined, so marking the conversation as the Space would
    /// write a flag the next sync erases.
    case agentNeverArrived(conversationId: String)
    /// Markers were written but the Space still doesn't read back, which means
    /// the derivation disagrees with what was just written.
    case provisionedButNotFound(conversationId: String)
    /// The service was torn down mid-provision.
    case provisioningUnavailable
}
