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
/// - Renders a dropdown header for picking between agents when the group
///   has two or more, attached outside the `.id` remount boundary so it
///   survives agent switches.
struct AgentPageView: View {
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
                AgentPageEmptyState(isReadOnly: isReadOnly, inviteAction: inviteAgent)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if agentInboxIds.count > 1 {
                agentPickerHeader
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

    /// The per-agent DM page, keyed so an agent switch remounts it.
    @ViewBuilder
    private func dmContent(agentInboxId: String) -> some View {
        AgentDmPageView(
            viewModel: viewModel,
            agentInboxId: agentInboxId,
            extraBottomInset: extraBottomInset,
            isReadOnly: isReadOnly,
            isActivePage: isActivePage,
            keyboardVisible: keyboardVisible,
            drivesWindowColorScheme: drivesWindowColorScheme
        )
        .id(agentInboxId)
    }

    // MARK: - Agent picker header (2+ agents)

    /// Bridges the optional bound selection to the picker's non-optional
    /// selection, animating agent switches.
    private var pickerBinding: Binding<String> {
        Binding(
            get: { resolvedAgentInboxId ?? "" },
            set: { newValue in
                withAnimation(.easeInOut(duration: Constant.selectionAnimationDuration)) {
                    selectedAgentInboxId = newValue
                }
            }
        )
    }

    private func displayName(for inboxId: String) -> String {
        let member = viewModel.conversation.members.first { $0.profile.inboxId == inboxId }
        return member?.profile.displayName ?? "Assistant"
    }

    private var selectedAgentName: String {
        guard let inboxId = resolvedAgentInboxId else { return "Assistant" }
        return displayName(for: inboxId)
    }

    private var agentPickerHeader: some View {
        Menu {
            Picker("Agent", selection: pickerBinding) {
                ForEach(agentInboxIds, id: \.self) { inboxId in
                    Text(displayName(for: inboxId))
                        .tag(inboxId)
                }
            }
        } label: {
            agentPickerLabel
        }
        .accessibilityIdentifier("agent-page-agent-picker")
    }

    private var agentPickerLabel: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            AgentPageGlyph(
                diameter: Constant.pickerGlyphDiameter,
                fontSize: Constant.pickerGlyphFontSize
            )
            Text(selectedAgentName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.top, DesignConstants.Spacing.step2x)
    }

    private enum Constant {
        static let selectionAnimationDuration: TimeInterval = 0.2
        static let pickerGlyphDiameter: CGFloat = 18.0
        static let pickerGlyphFontSize: CGFloat = 11.0
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
