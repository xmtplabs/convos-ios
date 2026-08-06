import SwiftUI

/// The composer-anchored page switcher shown when the new-composer flag is
/// active: "Group" and "Agent" pills that drive the conversation pager's
/// selected page in place of `ConversationPagerDots`. Both pills render
/// wherever the agent tab is available (the Agent pill targets the single
/// `.agent` page, which hosts its own agent selection and empty state);
/// otherwise only the Group pill renders. The Things page stays
/// swipe-reachable and shows as neither pill selected.
struct GroupAgentSwitcher: View {
    @Binding var selectedPage: ConversationPagerPage
    /// Whether the Agent pill renders; false leaves the Group pill alone.
    let showsAgentPill: Bool

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            pill(
                title: "Group",
                page: .messages,
                identifier: "switcher-group-pill"
            ) { color in
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 15.0, weight: .semibold))
                    .foregroundStyle(color)
            }
            if showsAgentPill {
                pill(
                    title: "Agent",
                    page: .agent,
                    identifier: "switcher-agent-pill"
                ) { color in
                    agentGlyph(color: color)
                }
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step2x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityIdentifier("group-agent-switcher")
    }

    @ViewBuilder
    private func pill(
        title: String,
        page: ConversationPagerPage,
        identifier: String,
        @ViewBuilder glyph: (Color) -> some View
    ) -> some View {
        let isSelected: Bool = page == selectedPage
        let color: Color = isSelected ? .primary : .colorFillTertiary
        let action = {
            withAnimation(.easeInOut(duration: 0.25)) {
                selectedPage = page
            }
        }
        Button(action: action) {
            VStack(spacing: DesignConstants.Spacing.stepX) {
                glyph(color)
                Text(title)
                    .font(.caption2)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(color)
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.vertical, DesignConstants.Spacing.stepX)
            .contentShape(.capsule)
            .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    /// The "A" avatar glyph, mirroring the agent indicator the pager dots use.
    private func agentGlyph(color: Color) -> some View {
        Text("A")
            .font(.system(size: 11.0, weight: .bold))
            .foregroundStyle(.background)
            .frame(width: 18.0, height: 18.0)
            .background(color, in: .circle)
    }
}
