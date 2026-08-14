import ConvosCore
import Foundation
import SwiftUI

/// Owns the binding between a conversation's Agent tab and the real agent-DM
/// conversation behind it. Lifted out of the agent page view so the two
/// surfaces that render the DM - the backing transcript and the sheet's
/// agent composer - share one view model and one binding lifecycle.
///
/// The DM is a separate 2-member conversation the agent creates (see
/// docs/plans/agent-dms.md). Until it syncs in, `dmViewModel` stays nil and
/// the Agent tab renders its empty state with a disabled composer; the
/// moment the agent-created DM arrives, `bindIfNeeded`/`rebindWhenDmAppears`
/// attach the real conversation and the composer enables.
@Observable
@MainActor
final class AgentDmSession {
    /// The origin conversation's view model; supplies session, messaging
    /// service, and the member roster the agent is resolved from.
    private let originViewModel: ConversationViewModel
    /// The agent this tab is bound to; nil while the conversation has no
    /// verified agent member yet.
    private(set) var agentInboxId: String?
    /// The agent DM's own view model once the DM conversation exists.
    private(set) var dmViewModel: ConversationViewModel?
    /// Set the moment the user asks for an agent, so the tab shows progress on
    /// the tap itself. Cleared when the agent lands, or by the timeout below
    /// when it never does.
    private(set) var isRequestingAgent: Bool = false
    /// True when the session is already provisioning this conversation's
    /// silent default agent - every conversation claimed from the warm cache
    /// has one on the way, so the tab must wait on it rather than offer to add
    /// another. Refreshed by `refreshDefaultAgentProvisioning()`.
    private(set) var isProvisioningDefaultAgent: Bool = false
    @ObservationIgnored
    private var requestTimeoutTask: Task<Void, Never>?

    init(originViewModel: ConversationViewModel) {
        self.originViewModel = originViewModel
    }

    /// The bound agent's member row in the origin conversation, if present.
    var agent: ConversationMember? {
        guard let agentInboxId else { return nil }
        return originViewModel.conversation.members.first { $0.profile.inboxId == agentInboxId }
    }

    var agentName: String {
        agent?.profile.displayName ?? "Assistant"
    }

    /// The conversation the tab belongs to. Its id changes when a new-convo
    /// flow settles from its placeholder draft onto the real conversation,
    /// which is the id any default-agent provision was registered under.
    var originConversationId: String {
        originViewModel.conversation.id
    }

    /// True while a join requested from this conversation is still in flight -
    /// the agent isn't a member yet, so there is nothing to bind to. Together
    /// with `agentInboxId` and `dmViewModel` this is what the Agent tab reads
    /// to decide between offering an agent, waiting on one, and showing the DM.
    ///
    /// `isRequestingAgent` is the near half of that: the view model's own
    /// pending flag is `@ObservationIgnored` and only turns over once the join
    /// registers, so on its own the tab would sit on the offer for a beat
    /// after the tap.
    var isJoiningAgent: Bool {
        isRequestingAgent || isProvisioningDefaultAgent || originViewModel.isAgentJoinPending
    }

    /// Asks the session whether this conversation's default agent is already
    /// being provisioned. Cheap, and worth re-running whenever the answer
    /// could have changed: on the conversation settling into its real id, and
    /// when the tab is shown.
    func refreshDefaultAgentProvisioning() async {
        guard agentInboxId == nil else {
            isProvisioningDefaultAgent = false
            return
        }
        let conversationId: String = originViewModel.conversation.id
        isProvisioningDefaultAgent = await originViewModel.session
            .isProvisioningDefaultAgent(id: conversationId)
    }

    /// Brings the conversation's default agent in - the Agent tab's "Add an
    /// agent" action, for a conversation that has none (one created before
    /// agents joined by default, or whose silent provision never landed).
    /// Takeable once: the tab moves to its progress state on the tap, and a
    /// second request is refused, so a double tap can't seat two agents.
    func requestAgentJoin() {
        guard !isRequestingAgent, agentInboxId == nil else { return }
        isRequestingAgent = true
        originViewModel.requestAgentJoin()
        // A join that never lands must not pin the progress bar forever; the
        // offer comes back so the user can try again.
        requestTimeoutTask?.cancel()
        requestTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Constant.requestTimeout))
            guard let self, !Task.isCancelled, self.agentInboxId == nil else { return }
            self.isRequestingAgent = false
        }
    }

    /// Points the session at an agent (or at none). A change tears down the
    /// current DM binding so the new agent's DM can bind in its place.
    func setAgent(inboxId: String?) {
        guard inboxId != agentInboxId else { return }
        // Clear any push-suppression lane registered for the outgoing DM;
        // nobody re-posts it with the old id once the binding is gone.
        if dmViewModel != nil {
            updateActiveDmLane(isActive: false)
        }
        agentInboxId = inboxId
        if inboxId != nil {
            requestTimeoutTask?.cancel()
            requestTimeoutTask = nil
            isRequestingAgent = false
            isProvisioningDefaultAgent = false
        }
        dmViewModel = nil
        bindIfNeeded()
    }

    /// Attaches the DM's view model when the DM conversation already exists.
    /// Safe to call repeatedly; a no-op once bound or while no agent is set.
    ///
    /// The messaging service comes from the session rather than from
    /// `originViewModel`: a conversation opened through the new-convo flow
    /// starts on a placeholder view model backed by a mock service, and
    /// handing that mock to the DM points its writer (and, through the mock's
    /// conversation publisher, the DM view model itself) at a draft that goes
    /// nowhere - the DM would render and accept sends that silently vanish.
    func bindIfNeeded() {
        guard dmViewModel == nil, let agentInboxId else { return }
        guard let existing = try? originViewModel.session
            .conversationsRepository(for: [.allowed, .unknown])
            .findAgentDm(with: agentInboxId) else {
            return
        }
        dmViewModel = ConversationViewModel(
            conversation: existing,
            session: originViewModel.session,
            messagingService: originViewModel.session.messagingServiceSync(),
            coreActions: originViewModel.coreActions
        )
    }

    /// The eager reconciler (or another device) can create the DM while the
    /// Agent tab is already mounted; a single bind attempt would leave it on
    /// the empty state until remount. Re-attempt the bind on every repository
    /// emission until it succeeds. Runs until cancelled; key it on the agent
    /// inbox id (`.task(id:)`).
    func rebindWhenDmAppears() async {
        guard dmViewModel == nil, agentInboxId != nil else { return }
        let publisher = originViewModel.session
            .conversationsRepository(for: [.allowed, .unknown])
            .conversationsPublisher
        for await _ in publisher.values {
            if Task.isCancelled || dmViewModel != nil { return }
            bindIfNeeded()
            if dmViewModel != nil { return }
        }
    }

    /// Clears the agent-DM lane's unread flag when the user views the Agent
    /// tab. The lane is its own conversation, so opening the parent (which
    /// only marks the group read) never cleared it - leaving the DM
    /// perpetually "unread" and routing every open back to it.
    func markDmAsRead() {
        guard let dmViewModel else { return }
        let conversationId: String = dmViewModel.conversation.id
        let messagingService = dmViewModel.messagingService
        Task {
            do {
                try await messagingService
                    .conversationLocalStateWriter()
                    .setUnread(false, for: conversationId)
            } catch {
                Log.warning("Failed marking agent DM as read: \(error.localizedDescription)")
            }
        }
    }

    /// Registers (or clears) this DM lane as the on-screen conversation with
    /// the session so a push for the DM the user is currently viewing is
    /// silenced. The lane is its own conversation whose id never appears in
    /// the parent's `activeConversationChanged` signal (that carries the
    /// group id), so it has to be tracked explicitly. A nil id when no DM is
    /// bound yet is a harmless clear.
    func updateActiveDmLane(isActive: Bool) {
        let conversationId: String? = isActive ? dmViewModel?.conversation.id : nil
        NotificationCenter.default.post(
            name: .activeDmConversationChanged,
            object: nil,
            userInfo: conversationId.map { ["conversationId": $0] } ?? [:]
        )
    }

    private enum Constant {
        /// Comfortably past the join's own registration deadline, so the offer
        /// only returns once the attempt has really failed.
        static let requestTimeout: Double = 90.0
    }
}
