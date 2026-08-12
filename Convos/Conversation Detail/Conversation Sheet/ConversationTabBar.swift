import ConvosComposer
import SwiftUI

/// The conversation sheet's tab bar: Desktop | Group | Agent slots that
/// drive the selected conversation surface. Styled after the system tab
/// bar's equal-width icon-over-label items, with native segmented-control
/// mechanics: one selection thumb that slides between slots, live tracking
/// while a finger is down (touch-down selects, dragging across slots moves
/// the selection with it), selection haptics, and a pressed-state thumb
/// compression - rather than discrete buttons whose highlight teleports.
struct ConversationTabBar: View {
    @Binding var selectedTab: ConversationTab
    /// Tabs to render, in order. The full set by default; hosts may trim it
    /// (e.g. a draft conversation with no desktop yet).
    var tabs: [ConversationTab] = ConversationTab.allCases

    /// True while a finger is on the bar; compresses the thumb slightly,
    /// mirroring the native segmented thumb's pressed state.
    @GestureState private var isTracking: Bool = false

    private var selectedIndex: Int {
        tabs.firstIndex(of: selectedTab) ?? 0
    }

    var body: some View {
        ZStack(alignment: .leading) {
            thumb
            HStack(spacing: Constant.slotSpacing) {
                ForEach(tabs) { tab in
                    slot(for: tab)
                }
            }
        }
        .contentShape(.rect)
        // A single tracking gesture owns both taps and drags (minimum
        // distance zero fires on touch-down), so selection follows the
        // finger the way the system segmented control's thumb does.
        .gesture(trackingGesture)
        .padding(Constant.capsulePadding)
        // The liquid-glass capsule the native floating tab bar rides in.
        .glassEffect(.regular.interactive(), in: .capsule)
        .sensoryFeedback(.selection, trigger: selectedTab)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-tab-bar")
    }

    /// The sliding selection thumb, filled with the design's selected-tab
    /// token (fill/subtle), which flips with the dark agent surface.
    private var thumb: some View {
        Capsule()
            .fill(DesignConstants.Colors.fillSubtle)
            .frame(width: Constant.slotWidth, height: Constant.slotHeight)
            .scaleEffect(isTracking ? Constant.trackingThumbScale : 1.0)
            .offset(x: CGFloat(selectedIndex) * (Constant.slotWidth + Constant.slotSpacing))
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: selectedIndex)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isTracking)
    }

    private var trackingGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($isTracking) { _, state, _ in
                state = true
            }
            .onChanged { value in
                select(atX: value.location.x)
            }
            .onEnded { value in
                select(atX: value.location.x)
            }
    }

    /// Maps a horizontal position on the bar to a slot and selects it. Live
    /// tracking: called on touch-down and every drag sample, clamped so a
    /// finger sliding off the bar's ends sticks to the edge slots.
    private func select(atX x: CGFloat) {
        let slotStride: CGFloat = Constant.slotWidth + Constant.slotSpacing
        let index: Int = min(max(Int(x / slotStride), 0), tabs.count - 1)
        let tab: ConversationTab = tabs[index]
        guard tab != selectedTab else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedTab = tab
        }
    }

    private func slot(for tab: ConversationTab) -> some View {
        let isSelected: Bool = tab == selectedTab
        return VStack(spacing: Constant.glyphLabelSpacing) {
            glyph(for: tab, isSelected: isSelected)
            Text(tab.title)
                .font(.system(size: Constant.labelPointSize, weight: .bold))
                .foregroundStyle(labelColor(isSelected: isSelected))
        }
        .frame(width: Constant.slotWidth, height: Constant.slotHeight)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("conversation-tab-\(tab.rawValue)")
    }

    /// Unselected treatment from the design: tertiary icon over a secondary
    /// label; both go primary when selected.
    private func iconColor(isSelected: Bool) -> Color {
        isSelected ? .colorTextPrimary : .colorTextTertiary
    }

    private func labelColor(isSelected: Bool) -> Color {
        isSelected ? .colorTextPrimary : .colorTextSecondary
    }

    @ViewBuilder
    private func glyph(for tab: ConversationTab, isSelected: Bool) -> some View {
        switch tab {
        case .desktop:
            symbolGlyph("macwindow", isSelected: isSelected)
        case .group:
            symbolGlyph("message.fill", isSelected: isSelected)
        case .agent:
            agentGlyph(isSelected: isSelected)
        }
    }

    private func symbolGlyph(_ name: String, isSelected: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: Constant.iconPointSize, weight: .semibold))
            .foregroundStyle(iconColor(isSelected: isSelected))
            .frame(height: Constant.iconSlotHeight)
    }

    /// The agent glyph: the shared `addAgentIcon` asset in a badge circle,
    /// sized to sit in the same icon slot as the symbol slots.
    private func agentGlyph(isSelected: Bool) -> some View {
        Image("addAgentIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.background)
            .frame(width: Constant.agentGlyphSize, height: Constant.agentGlyphSize)
            .frame(width: Constant.agentBadgeSize, height: Constant.agentBadgeSize)
            .background(iconColor(isSelected: isSelected), in: .circle)
            .frame(height: Constant.iconSlotHeight)
    }

    private enum Constant {
        /// The native segmented thumb compresses slightly under a finger.
        static let trackingThumbScale: CGFloat = 0.95
        /// Inset between the glass capsule's edge and the slots, equal on
        /// all sides (Figma track p-4).
        static let capsulePadding: CGFloat = DesignConstants.Spacing.stepX
        /// Slots sit adjacent inside the track (Figma tabs stack with no
        /// gap).
        static let slotSpacing: CGFloat = 0.0
        /// Slot metrics from Figma 7156:13839: fixed 102x54 slots so the
        /// tabs read as uniform regardless of label.
        static let slotWidth: CGFloat = 102.0
        static let slotHeight: CGFloat = 54.0
        /// 17pt semibold symbols in a 28pt icon slot over 10pt bold labels,
        /// tightly stacked (gap 1).
        static let iconPointSize: CGFloat = 17.0
        static let labelPointSize: CGFloat = 10.0
        static let iconSlotHeight: CGFloat = 28.0
        static let glyphLabelSpacing: CGFloat = 1.0
        /// The agent badge circle and the optical size of the `addAgentIcon`
        /// glyph inside it, filling the icon slot like the symbols do.
        static let agentBadgeSize: CGFloat = 24.0
        static let agentGlyphSize: CGFloat = 13.0
    }
}

#Preview {
    @Previewable @State var selectedTab: ConversationTab = .group
    ConversationTabBar(selectedTab: $selectedTab)
        .padding()
        .background(.colorBackgroundSurfaceless)
}
