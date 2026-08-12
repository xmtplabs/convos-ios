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

    /// The sliding selection thumb. `Color.primary`-based so it lightens on
    /// the dark agent surface and tints on the light group surface.
    private var thumb: some View {
        Capsule()
            .fill(Color.primary.opacity(Constant.thumbFillOpacity))
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
                .font(.system(size: Constant.labelPointSize, weight: .medium))
                .foregroundStyle(slotColor(isSelected: isSelected))
        }
        .frame(width: Constant.slotWidth, height: Constant.slotHeight)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("conversation-tab-\(tab.rawValue)")
    }

    /// Unselected slots dim to secondary, matching the system tab bar's
    /// unselected item treatment.
    private func slotColor(isSelected: Bool) -> Color {
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
            .font(.system(size: Constant.iconPointSize, weight: .medium))
            .foregroundStyle(slotColor(isSelected: isSelected))
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
            .background(slotColor(isSelected: isSelected), in: .circle)
            .frame(height: Constant.iconSlotHeight)
    }

    private enum Constant {
        /// Fill of the sliding selection thumb.
        static let thumbFillOpacity: Double = 0.08
        /// The native segmented thumb compresses slightly under a finger.
        static let trackingThumbScale: CGFloat = 0.95
        /// Inset between the glass capsule's edge and the slots, equal on
        /// all sides (mirrors the home control).
        static let capsulePadding: CGFloat = DesignConstants.Spacing.stepX
        static let slotSpacing: CGFloat = DesignConstants.Spacing.stepX
        /// Fixed slot size, mirroring the equal-width items of the system
        /// tab bar so the tabs read as uniform slots regardless of label.
        static let slotWidth: CGFloat = 90.0
        /// Icon slot + label + the former vertical padding, kept explicit so
        /// the thumb and the slots share one frame.
        static let slotHeight: CGFloat = 52.0
        /// Metrics mirroring the system tab bar items on the home screen:
        /// ~18pt medium symbols over 10pt medium labels, tightly stacked.
        static let iconPointSize: CGFloat = 18.0
        static let labelPointSize: CGFloat = 10.0
        /// Fixed icon slot so the symbols and the agent badge baseline-align
        /// their labels across slots.
        static let iconSlotHeight: CGFloat = 22.0
        static let glyphLabelSpacing: CGFloat = 2.0
        /// The agent badge circle and the optical size of the `addAgentIcon`
        /// glyph inside it, filling the icon slot like the symbols do.
        static let agentBadgeSize: CGFloat = 22.0
        static let agentGlyphSize: CGFloat = 12.0
    }
}

#Preview {
    @Previewable @State var selectedTab: ConversationTab = .group
    ConversationTabBar(selectedTab: $selectedTab)
        .padding()
        .background(.colorBackgroundSurfaceless)
}
