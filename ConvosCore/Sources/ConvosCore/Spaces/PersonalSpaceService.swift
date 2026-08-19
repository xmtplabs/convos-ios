import Foundation

/// Finds - and the first time, provisions - the user's personal Space: the
/// conversation the Space Home renders, holding their notes, events and
/// reminders.
///
/// The Space is an ordinary conversation wearing two constraints:
///
/// - **Two members**, the user and their own agent. The agent comes free:
///   every conversation in the warm cache has a default agent added while it
///   is still hidden, so claiming one claims an agent with it.
/// - **Locked**, so nobody can be invited. `lockConversation` sets the group's
///   add-member policy to `deny`, which is the same lock the UI offers
///   elsewhere - the Space is not a special case the permission system has to
///   learn about.
///
/// Everything else about it is unremarkable, and that is the point. An earlier
/// version also marked it as an agent DM, because an origin-less agent DM was
/// a marker the app already understood and nothing new had to be invented.
/// That marker turned out not to be a label: it rides the wire in
/// `ConversationCustomMetadata`, the assistant runtime reads it too, and on
/// seeing it the runtime did exactly what it is supposed to do for a room that
/// claims to be a DM with an agent - it opened a *separate* DM for that agent
/// and the agent left the Space. A Space with no agent in it also never gets a
/// `spaceUrl`, since the Assistant Worker publishes those for rooms it is the
/// agent of, so the Home stayed empty for the same reason.
///
/// So the Space is designated by `ConversationLocalState.isPersonalSpace`, a
/// flag no other device and no server ever sees. Nothing can act on it but us.
/// The cost is that it does not survive a reinstall or reach a second device;
/// a synced marker would, and would need the Worker to understand it.
public actor PersonalSpaceService {
    private let session: any SessionManagerProtocol
    /// One provision at a time. Two callers arriving together (the Space Home
    /// appearing while a push wakes the app) would otherwise each claim a
    /// different pooled conversation and designate both.
    private var provisionTask: Task<Conversation, Error>?

    public init(session: any SessionManagerProtocol) {
        self.session = session
    }

    /// The user's Space, provisioning one if this is the first time it has
    /// been asked for. Safe to call on every appearance of the Space Home:
    /// the common path is a single indexed read.
    public func personalSpace() async throws -> Conversation {
        if let existing = try findExisting() {
            ensureAgentPresent(in: existing)
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

    /// The Space always has an agent in it. That is the whole promise of the
    /// screen - it is the room you talk to your agent in - so an empty one is
    /// repaired rather than reported.
    ///
    /// An agent can go missing for reasons that have nothing to do with this
    /// device: it can be reaped, or it can leave. `ensureDefaultAgentConversationReady`
    /// is idempotent and shares one task per conversation, so calling it on
    /// every resolve costs nothing when the agent is already there.
    /// Deliberately not awaited: a missing agent should not hold up drawing a
    /// Space the user can already read.
    private func ensureAgentPresent(in space: Conversation) {
        guard !space.members.contains(where: \.isVerifiedAgent) else { return }
        Log.warning("Personal Space \(space.id) has no agent; re-provisioning one")
        Task { [session] in
            await session.reprovisionDefaultAgent(id: space.id)
        }
    }

    private func provision() async throws -> Conversation {
        // Re-check inside the task: a provision that completed while this one
        // was queued behind it has already made the Space.
        if let existing = try findExisting() {
            return existing
        }

        let conversationId = try await claimPooledConversation()

        // Commit before designating. The lock is written against the XMTP
        // group, and a row still flagged unused is one the user cannot see if
        // anything below fails - better a visible conversation missing its
        // lock than an invisible one holding the Space's identity.
        await session.commitClaimedConversation(id: conversationId)

        await session.ensureDefaultAgentConversationReady(id: conversationId)
        try await awaitAgentMember(in: conversationId)

        try await session.messagingService().conversationMetadataWriter()
            .lockConversation(for: conversationId)
        try await session.messagingService().conversationLocalStateWriter()
            .setPersonalSpace(true, for: conversationId)

        guard let space = try findExisting() else {
            throw PersonalSpaceError.provisionedButNotFound(conversationId: conversationId)
        }
        Log.info("Personal Space provisioned: \(conversationId)")
        return space
    }

    /// Claims a conversation from the warm cache, waiting for the pool to fill
    /// if it has to.
    ///
    /// On a first launch it always has to: the Space Home is the first screen
    /// the app shows, and nothing has pre-created a group yet. Giving up on the
    /// first empty read left the front door saying the Space wasn't ready while
    /// the pool filled seconds later. Retrying is also what makes the pool
    /// fill - `prepareNewConversation` schedules the next prewarm on its way
    /// out, so the first miss is what starts the work the second one collects.
    private func claimPooledConversation() async throws -> String {
        for attempt in 0..<Self.claimAttempts {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(Self.claimRetryMilliseconds))
            }
            let (_, claimed) = await session.prepareNewConversation()
            if let claimed {
                return claimed
            }
        }
        throw PersonalSpaceError.noPooledConversation
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
    private static let claimAttempts: Int = 15
    private static let claimRetryMilliseconds: Int = 1000
    private static let agentPollAttempts: Int = 20
    private static let agentPollIntervalMilliseconds: Int = 500
}

// MARK: - Errors

public enum PersonalSpaceError: Error, Equatable {
    /// The warm cache had nothing to claim. Transient: the pool refills.
    case noPooledConversation
    /// The agent never joined, so designating the conversation would hand the
    /// Space Home a room with nobody to talk to.
    case agentNeverArrived(conversationId: String)
    /// The Space was designated but still doesn't read back, which means the
    /// query disagrees with what was just written.
    case provisionedButNotFound(conversationId: String)
    /// The service was torn down mid-provision.
    case provisioningUnavailable
}
