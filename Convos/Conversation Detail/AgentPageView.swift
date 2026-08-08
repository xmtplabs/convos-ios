import ConvosComposer
import ConvosCore
import SwiftUI

/// The single "Agent" tab page for the Group/Agent switcher: one container
/// regardless of how many verified agents are in the group.
///
/// Responsibilities:
/// - Resolves the selected agent: the bound selection when it is still a
///   member of `agentInboxIds`, otherwise the first (join-ordered) agent.
///   Selection therefore falls back to the first agent when the selected
///   one leaves the conversation.
/// - Hosts one `AgentDmPageView` per resolved agent, keyed by `.id` so
///   switching agents tears down and remounts the DM page (state, focus,
///   and DM binding reset).
/// - Shows an "invite an agent" empty state when the group has no agents,
///   opening the agent builder via the conversation view model's existing
///   sheet.
/// - Feeds an `AgentSwitcherContext` into the composer when the group has
///   two or more agents, so the compose bar shows the switcher bubble that
///   moves between agents.
struct AgentPageView: View {
    @Environment(\.desktopTranscriptOpacity) private var desktopTranscriptOpacity: Double
    @Bindable var viewModel: ConversationViewModel
    /// Join-ordered inbox ids of the conversation's verified agents.
    let agentInboxIds: [String]
    @Binding var selectedAgentInboxId: String?
    let extraBottomInset: CGFloat
    let isReadOnly: Bool
    let isActivePage: Bool
    let keyboardVisible: Bool
    /// Whether the active page drives the window-wide dark flip via
    /// `.preferredColorScheme`. Desktop mode passes false: there the host
    /// darkens only the chat drawer (transcript, switcher, and composer), so
    /// the rest of the app keeps the ambient scheme.
    var drivesWindowColorScheme: Bool = true
    /// Forwarded to the DM page's transcript (and applied to the empty state
    /// and picker header) so the desktop drawer's collapsed compose card
    /// shows the composer alone. 1 outside desktop mode.
    var transcriptOpacity: Double = 1.0

    private var effectiveTranscriptOpacity: Double {
        transcriptOpacity * desktopTranscriptOpacity
    }

    /// The bound selection when it still names a current agent, else the
    /// first agent, else nil (empty state).
    private var resolvedAgentInboxId: String? {
        guard let selected = selectedAgentInboxId, agentInboxIds.contains(selected) else {
            return agentInboxIds.first
        }
        return selected
    }

    /// `.dark` while this page is active and window-driving is enabled; nil
    /// otherwise so the rest of the app keeps the ambient scheme.
    private var windowColorScheme: ColorScheme? {
        guard drivesWindowColorScheme && isActivePage else { return nil }
        return .dark
    }

    var body: some View {
        ZStack {
            if let resolvedAgentInboxId {
                dmContent(agentInboxId: resolvedAgentInboxId)
            } else {
                emptyStateWithComposer
            }
        }
        // AgentDmPageView applies these same modifiers internally for the DM
        // case; hoisting identical values here is idempotent there and brings
        // the empty state and picker header into the same dark treatment.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(windowColorScheme)
    }

    private func inviteAgent() {
        viewModel.presentAgentBuilder()
    }

    /// The no-agent state with the inert "Agent" composer pinned beneath it.
    /// Only the empty-state content fades with `transcriptOpacity`; the
    /// composer bar always renders, so the desktop drawer's collapsed
    /// compose card wraps a visible bar even before any agent exists.
    private var emptyStateWithComposer: some View {
        AgentPageEmptyState(isReadOnly: isReadOnly, inviteAction: inviteAgent)
            .opacity(effectiveTranscriptOpacity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                AgentInertComposerBar(placeholder: "Agent")
            }
    }

    /// The per-agent DM page, keyed so an agent switch remounts it. The switcher
    /// context is injected outside the `.id` boundary's effect (the environment
    /// flows into the remounted page) so the composer's switcher bubble always
    /// reflects the current agent and the other agents to move to.
    @ViewBuilder
    private func dmContent(agentInboxId: String) -> some View {
        AgentDmPageView(
            viewModel: viewModel,
            agentInboxId: agentInboxId,
            extraBottomInset: extraBottomInset,
            isReadOnly: isReadOnly,
            isActivePage: isActivePage,
            keyboardVisible: keyboardVisible,
            drivesWindowColorScheme: drivesWindowColorScheme,
            transcriptOpacity: transcriptOpacity
        )
        .id(agentInboxId)
        .environment(\.agentSwitcher, agentSwitcherContext(for: agentInboxId))
    }

    // MARK: - Agent switcher (2+ agents)

    private func displayName(for inboxId: String) -> String {
        let member = viewModel.conversation.members.first { $0.profile.inboxId == inboxId }
        return member?.profile.displayName ?? "Assistant"
    }

    /// The switcher context handed to the composer for the given agent: the
    /// selected agent's avatar and the other agents to move to. `nil` when the
    /// conversation has a single agent (nothing to switch between) or the
    /// selected member is momentarily missing, so the bubble simply isn't drawn.
    private func agentSwitcherContext(for agentInboxId: String) -> AgentSwitcherContext? {
        guard agentInboxIds.count > 1,
              let selected = viewModel.conversation.members.first(where: { $0.profile.inboxId == agentInboxId }) else {
            return nil
        }
        let others: [AgentSwitcherOption] = agentInboxIds
            .filter { $0 != agentInboxId }
            .compactMap { inboxId in
                guard let member = viewModel.conversation.members.first(where: { $0.profile.inboxId == inboxId }) else {
                    return nil
                }
                return AgentSwitcherOption(
                    inboxId: inboxId,
                    profile: member.profile,
                    displayName: displayName(for: inboxId)
                )
            }
        guard !others.isEmpty else { return nil }
        return AgentSwitcherContext(
            selectedProfile: selected.profile,
            selectedVerification: selected.agentVerification,
            otherAgents: others,
            onSelect: { newInboxId in
                withAnimation(.easeInOut(duration: Constant.selectionAnimationDuration)) {
                    selectedAgentInboxId = newInboxId
                }
            }
        )
    }

    private enum Constant {
        static let selectionAnimationDuration: TimeInterval = 0.2
    }
}

/// Empty state for a conversation with no verified agents: the agent glyph,
/// a short prompt, and a button that opens the agent builder via the origin
/// conversation view model's existing sheet.
private struct AgentPageEmptyState: View {
    let isReadOnly: Bool
    let inviteAction: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step6x) {
            AgentPageGlyph(
                diameter: Constant.glyphDiameter,
                fontSize: Constant.glyphFontSize
            )
            VStack(spacing: DesignConstants.Spacing.stepX) {
                Text("No agent yet")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Text("Make an agent for this convo")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }
            inviteButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.colorBackgroundSurfaceless)
    }

    private var inviteButton: some View {
        let action = inviteAction
        return Button("Invite an agent", action: action)
            .convosButtonStyle(.rounded(fullWidth: false))
            .disabled(isReadOnly)
            .accessibilityIdentifier("agent-page-invite-agent-button")
    }

    private enum Constant {
        static let glyphDiameter: CGFloat = 64.0
        static let glyphFontSize: CGFloat = 40.0
    }
}

/// The "A" agent glyph, mirroring `GroupAgentSwitcher`'s pill glyph but
/// parameterized so the picker header and empty state can size it.
private struct AgentPageGlyph: View {
    let diameter: CGFloat
    let fontSize: CGFloat

    var body: some View {
        Text("A")
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(.background)
            .frame(width: diameter, height: diameter)
            .background(Color.primary, in: .circle)
    }
}

#Preview {
    @Previewable @State var selectedAgentInboxId: String?
    AgentPageView(
        viewModel: .mock,
        agentInboxIds: [],
        selectedAgentInboxId: $selectedAgentInboxId,
        extraBottomInset: 0,
        isReadOnly: false,
        isActivePage: true,
        keyboardVisible: false
    )
}
