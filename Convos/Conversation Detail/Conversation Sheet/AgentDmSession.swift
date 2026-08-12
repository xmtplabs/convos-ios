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
        dmViewModel = nil
        bindIfNeeded()
    }

    /// Attaches the DM's view model when the DM conversation already exists.
    /// Safe to call repeatedly; a no-op once bound or while no agent is set.
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
            messagingService: originViewModel.messagingService,
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
}
