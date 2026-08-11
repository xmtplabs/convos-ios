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
    /// The desktop conversation adopts the selected-pill treatment used by
    /// the home control. The default preserves the non-desktop presentation.
    var usesHomeStyle: Bool = false

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            pill(
                title: "Group",
                page: .messages,
                identifier: "switcher-group-pill"
            ) { color in
                Image(systemName: usesHomeStyle ? ConvosTab.chats.symbol : "bubble.left.fill")
                    .font(.system(size: Constant.iconPointSize, weight: .medium))
                    .foregroundStyle(color)
                    .frame(height: Constant.iconSlotHeight)
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
        .padding(.horizontal, Constant.togglePaddingHorizontal)
        .padding(.top, Constant.togglePaddingTop)
        .padding(.bottom, Constant.togglePaddingBottom)
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
        let color: Color = .colorTextPrimary
        let action = {
            withAnimation(.easeInOut(duration: 0.25)) {
                selectedPage = page
            }
        }
        Button(action: action) {
            VStack(spacing: Constant.glyphLabelSpacing) {
                glyph(color)
                Text(title)
                    .font(.system(size: Constant.labelPointSize, weight: .medium))
                    .foregroundStyle(color)
                    .fixedSize(horizontal: usesHomeStyle, vertical: usesHomeStyle)
            }
            .frame(width: Constant.pillWidth)
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .background {
                if usesHomeStyle && isSelected {
                    Capsule()
                        .fill(Color.primary.opacity(Constant.selectedFillOpacity))
                }
            }
            .contentShape(.capsule)
            .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    /// The agent glyph: the shared `addAgentIcon` asset in a badge circle,
    /// sized to sit in the same icon slot as the Group pill's symbol.
    private func agentGlyph(color: Color) -> some View {
        Image("addAgentIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.background)
            .frame(width: Constant.agentGlyphSize, height: Constant.agentGlyphSize)
            .frame(width: Constant.agentBadgeSize, height: Constant.agentBadgeSize)
            .background(color, in: .circle)
            .frame(height: Constant.iconSlotHeight)
    }

    private enum Constant {
        /// Fill of the selected pill's capsule highlight; `Color.primary`
        /// based so it lightens the pill inside the dark agent drawer and
        /// tints it in the light group surface.
        static let selectedFillOpacity: Double = 0.08
        /// Space above and below the switcher capsule, tuning its distance
        /// from the composer above and the drawer edge below.
        static let togglePaddingTop: CGFloat = DesignConstants.Spacing.stepX
        static let togglePaddingBottom: CGFloat = DesignConstants.Spacing.stepX
        /// Inset between the capsule edge and the pills, equal on all sides.
        static let togglePaddingHorizontal: CGFloat = DesignConstants.Spacing.stepX
        /// Fixed pill width, mirroring the equal-width items of the system
        /// tab bar so both tabs read as uniform slots regardless of label.
        static let pillWidth: CGFloat = 90.0
        /// Metrics mirroring the system tab bar items on the home screen:
        /// ~18pt medium symbols over 10pt medium labels, tightly stacked.
        static let iconPointSize: CGFloat = 18.0
        static let labelPointSize: CGFloat = 10.0
        /// Fixed icon slot so the symbol and the agent badge baseline-align
        /// their labels across pills.
        static let iconSlotHeight: CGFloat = 22.0
        static let glyphLabelSpacing: CGFloat = 2.0
        /// The agent badge circle and the optical size of the `addAgentIcon`
        /// glyph inside it, filling the icon slot like the symbol does.
        static let agentBadgeSize: CGFloat = 22.0
        static let agentGlyphSize: CGFloat = 12.0
    }
}
