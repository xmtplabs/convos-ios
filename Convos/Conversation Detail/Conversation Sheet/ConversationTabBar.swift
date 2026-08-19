import ConvosComposer
import SwiftUI

/// The conversation sheet's tab bar: Group | Agent slots that drive which
/// transcript the sheet hosts. Styled after the system tab
/// bar's equal-width icon-over-label items, with native segmented-control
/// mechanics: one selection thumb that slides between slots, live tracking
/// while a finger is down (touch-down selects, dragging across slots moves
/// the selection with it), selection haptics, and a pressed-state thumb
/// compression - rather than discrete buttons whose highlight teleports.
struct ConversationTabBar: View {
    @Binding var selectedTab: ConversationTab
    /// Tabs to render, in order. The full set by default; hosts may trim it
    /// (e.g. a draft conversation with no home yet).
    var tabs: [ConversationTab] = ConversationTab.allCases
    /// Tabs carrying an unread indicator: a dot on the icon's top-right
    /// corner (Figma 7488:14106). Hosts exclude the active tab - the user
    /// is looking at it.
    var badgedTabs: Set<ConversationTab> = []
    /// Fired when a tap lands on the already-selected tab (the native tab
    /// bar's re-tap contract: pop to root / scroll to top). Not fired when a
    /// drag visits other slots before returning.
    var onReselect: (ConversationTab) -> Void = { _ in }
    /// Whether a tab reads as active at all.
    ///
    /// False with the sheet away: the capsule still names which lane a tap would
    /// open, but neither lane is being shown, so marking one active would claim a
    /// transcript is on screen when the Home has the whole screen.
    var showsSelection: Bool = true

    /// True while a finger is on the bar; compresses the thumb slightly,
    /// mirroring the native segmented thumb's pressed state.
    @GestureState private var isTracking: Bool = false
    /// Which tab was selected when the current gesture began.
    ///
    /// Written on the gesture's first event, before the selection can move, and
    /// cleared when the gesture ends *or is cancelled*. Both halves matter: a
    /// flag cleared only in `onEnded` goes stale when raising the sheet cancels
    /// the gesture mid-flight, and a start captured after the selection has
    /// already moved makes every tab switch look like a re-tap.
    @State private var selectionAtGestureStart: ConversationTab?
    /// Whether the selection moved at any point during the current gesture.
    ///
    /// Start and end tab alone cannot tell a tap from a drag that crossed to the
    /// other lane and came back, and the two mean opposite things: the round trip
    /// is a lane switch, and collapsing the sheet under it is the last thing the
    /// finger asked for. Cleared alongside `selectionAtGestureStart`, so a
    /// cancelled gesture cannot leave it set for the next one to inherit.
    @State private var didMoveSelectionDuringGesture: Bool = false

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
        // Cleared when the gesture ends *or is cancelled* - the gesture state
        // resets itself either way - so a cancelled gesture cannot leave a stale
        // start behind for the next one to inherit.
        .onChange(of: isTracking) { _, tracking in
            guard !tracking else { return }
            selectionAtGestureStart = nil
            didMoveSelectionDuringGesture = false
        }
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
            .opacity(showsSelection ? 1 : 0)
            .frame(width: Constant.slotWidth, height: Constant.slotHeight)
            .scaleEffect(isTracking ? Constant.trackingThumbScale : 1.0)
            .offset(x: CGFloat(selectedIndex) * (Constant.slotWidth + Constant.slotSpacing))
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: selectedIndex)
            .animation(.easeInOut(duration: 0.2), value: showsSelection)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isTracking)
    }

    private var trackingGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($isTracking) { _, state, _ in
                state = true
            }
            .onChanged { value in
                // Captured here, before the selection can move, and only once per
                // gesture. Capturing it from `isTracking` instead ran *after*
                // `onChanged` had already switched tabs, so the start looked like
                // the destination and every switch read as a re-tap - which closed
                // the sheet instead of changing lane.
                if selectionAtGestureStart == nil {
                    selectionAtGestureStart = selectedTab
                }
                select(atX: value.location.x)
            }
            .onEnded { value in
                // Resolved before the release can move the selection: a state
                // written and read inside one callback is not guaranteed to read
                // back what was just written, and this answer must not depend on
                // that. Everything it reads is settled by earlier events.
                let endTab: ConversationTab? = tab(atX: value.location.x)
                let isReselect: Bool = !didMoveSelectionDuringGesture
                    && selectionAtGestureStart != nil
                    && endTab == selectionAtGestureStart
                select(atX: value.location.x)
                // A re-tap is a gesture that began on the tab it ended on and
                // never moved the selection in between.
                if isReselect, let endTab {
                    onReselect(endTab)
                }
            }
    }

    /// The slot under a horizontal position on the bar, clamped so a finger
    /// sliding off the bar's ends sticks to the edge slots. Nil only for an
    /// empty `tabs` array.
    private func tab(atX x: CGFloat) -> ConversationTab? {
        guard !tabs.isEmpty else { return nil }
        let slotStride: CGFloat = Constant.slotWidth + Constant.slotSpacing
        let index: Int = min(max(Int(x / slotStride), 0), tabs.count - 1)
        return tabs[index]
    }

    /// Maps a horizontal position on the bar to a slot and selects it. Live
    /// tracking: called on touch-down and every drag sample.
    private func select(atX x: CGFloat) {
        guard let tab = tab(atX: x), tab != selectedTab else { return }
        didMoveSelectionDuringGesture = true
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedTab = tab
        }
    }

    private func slot(for tab: ConversationTab) -> some View {
        let isSelected: Bool = showsSelection && tab == selectedTab
        let isBadged: Bool = badgedTabs.contains(tab)
        return VStack(spacing: Constant.glyphLabelSpacing) {
            glyph(for: tab, isSelected: isSelected)
                .overlay(alignment: .topTrailing) {
                    if isBadged {
                        unreadDot
                    }
                }
            Text(tab.title)
                .font(.system(size: Constant.labelPointSize, weight: .bold))
                .foregroundStyle(labelColor(isSelected: isSelected))
        }
        .frame(width: Constant.slotWidth, height: Constant.slotHeight)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isBadged ? "Unread" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("conversation-tab-\(tab.rawValue)")
    }

    /// The unread indicator, riding the icon's top-right corner. The ring
    /// in the card's fill color cuts the dot out of the icon beneath it.
    private var unreadDot: some View {
        Circle()
            .fill(Color.colorOrange)
            .frame(width: Constant.unreadDotSize, height: Constant.unreadDotSize)
            .padding(Constant.unreadDotRingWidth)
            .background(Color.colorBackgroundRaised, in: .circle)
            .offset(x: Constant.unreadDotOffset, y: -Constant.unreadDotOffset)
            .transition(.scale.combined(with: .opacity))
            .accessibilityHidden(true)
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
    /// sized to sit in the same icon slot as the symbol slots. The glyph is
    /// cut out in the card's fill color - `.background` resolves against the
    /// glass capsule and can vanish into the badge on the dark agent
    /// surface.
    private func agentGlyph(isSelected: Bool) -> some View {
        Image("addAgentIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color.colorBackgroundRaised)
            .frame(width: Constant.agentGlyphSize, height: Constant.agentGlyphSize)
            .frame(width: Constant.agentBadgeSize, height: Constant.agentBadgeSize)
            .background(iconColor(isSelected: isSelected), in: .circle)
            .frame(height: Constant.iconSlotHeight)
    }

    /// The two numbers other parties need: the sheet insets its composer by the
    /// capsule's height, and the Home reserves the same clearance. Re-exposed
    /// from `Constant` so the capsule stays the single source of its own size.
    enum Metrics {
        static let slotHeight: CGFloat = Constant.slotHeight
        static let capsulePadding: CGFloat = Constant.capsulePadding
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
        /// Slot metrics from Figma 7156:13839: fixed-width slots so the tabs read
        /// as uniform regardless of label.
        /// 180pt of buttons across the capsule's 188, split in two.
        static let slotWidth: CGFloat = 90.0
        /// Sized so the capsule matches the system's floating tab bar exactly:
        /// measured at 52pt tall, less the track padding on either side. The two
        /// sit in the same place on screen and have to read as the same control.
        static let slotHeight: CGFloat = ConversationSheetMetrics.capsuleHeight - capsulePadding * 2
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
        /// The unread dot on the icon's top-right corner (Figma 7488:14106),
        /// cut out of the icon by a ring in the card's fill color.
        static let unreadDotSize: CGFloat = 10.0
        static let unreadDotRingWidth: CGFloat = 2.0
        static let unreadDotOffset: CGFloat = 4.0
    }
}

#Preview {
    @Previewable @State var selectedTab: ConversationTab = .group
    ConversationTabBar(selectedTab: $selectedTab)
        .padding()
        .background(.colorBackgroundSurfaceless)
}
