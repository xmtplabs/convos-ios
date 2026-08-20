import SwiftUI

/// The conversation's Group | Agent | Context selector, floating in the top
/// chrome under the conversation's title capsule.
///
/// A pill segmented control rather than the system's: the design (Figma
/// 8007:27595) puts a raised white chip behind the selected label on an
/// otherwise transparent track, over a blurred gradient, which
/// `.pickerStyle(.segmented)` has no way to express.
///
/// The selection chip is one view moved between slots by
/// `matchedGeometryEffect`, not a background drawn per slot. That is what lets
/// the slots size to their own labels - the previous bar could hard-code equal
/// 102pt slots because it drew icons, and "Context" is not the width of
/// "Agent".
struct ConversationSegmentedControl: View {
    @Binding var selectedTab: ConversationTab
    /// Tabs to render, in order. Hosts trim it - a conversation with no agent
    /// has no Agent tab.
    var tabs: [ConversationTab] = ConversationTab.allCases
    /// Tabs carrying an unread dot. Hosts exclude the selected tab: the user is
    /// looking at it.
    var badgedTabs: Set<ConversationTab> = []

    @Namespace private var chipNamespace: Namespace.ID

    var body: some View {
        HStack(spacing: Constant.slotSpacing) {
            ForEach(tabs) { tab in
                segment(for: tab)
            }
        }
        .sensoryFeedback(.selection, trigger: selectedTab)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-segmented-control")
    }

    private func segment(for tab: ConversationTab) -> some View {
        let isSelected: Bool = tab == selectedTab
        let isBadged: Bool = badgedTabs.contains(tab)
        let labelColor: Color = isSelected ? .colorTextPrimary : .colorTextSecondary
        let labelWeight: Font.Weight = isSelected ? .medium : .regular
        let action = {
            guard tab != selectedTab else { return }
            withAnimation(.spring(response: Constant.chipResponse, dampingFraction: Constant.chipDamping)) {
                selectedTab = tab
            }
        }
        return Button(action: action) {
            Text(tab.title)
                .font(.system(size: Constant.labelPointSize, weight: labelWeight))
                .foregroundStyle(labelColor)
                .padding(.horizontal, Constant.slotHorizontalPadding)
                .padding(.vertical, Constant.slotVerticalPadding)
                .overlay(alignment: .topTrailing) {
                    if isBadged {
                        unreadDot
                    }
                }
                .background {
                    if isSelected {
                        selectionChip
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isBadged ? "Unread" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("conversation-tab-\(tab.rawValue)")
    }

    /// The raised chip behind the selected label. Shared across slots through
    /// the namespace, so selection slides it rather than cross-fading two of
    /// them.
    private var selectionChip: some View {
        Capsule()
            .fill(Color.colorBackgroundRaised)
            .shadow(
                color: .black.opacity(Constant.chipShadowOpacity),
                radius: Constant.chipShadowRadius,
                y: Constant.chipShadowYOffset
            )
            .matchedGeometryEffect(id: Constant.chipMatchId, in: chipNamespace)
    }

    /// The unread indicator on a tab the user is not looking at, cut out of the
    /// label by a ring in the chrome's own fill.
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

    private enum Constant {
        /// Figma 8007:27595 - slots sit 2pt apart on a transparent track.
        static let slotSpacing: CGFloat = DesignConstants.Spacing.stepHalf
        /// Figma 8007:27596 - px-12 py-6 around a 15pt label.
        static let slotHorizontalPadding: CGFloat = DesignConstants.Spacing.step3x
        static let slotVerticalPadding: CGFloat = 6.0
        static let labelPointSize: CGFloat = 15.0
        /// The selected chip's "cheap glass" drop shadow: 0/4/8 at 8% black.
        static let chipShadowOpacity: Double = 0.08
        static let chipShadowRadius: CGFloat = 8.0
        static let chipShadowYOffset: CGFloat = 4.0
        static let chipMatchId: String = "conversation-segment-chip"
        static let chipResponse: Double = 0.32
        static let chipDamping: Double = 0.85
        static let unreadDotSize: CGFloat = 8.0
        static let unreadDotRingWidth: CGFloat = 2.0
        static let unreadDotOffset: CGFloat = 2.0
    }
}

#Preview {
    @Previewable @State var selectedTab: ConversationTab = .group
    VStack(spacing: 40.0) {
        ConversationSegmentedControl(selectedTab: $selectedTab)
        ConversationSegmentedControl(selectedTab: $selectedTab, badgedTabs: [.agent])
        ConversationSegmentedControl(selectedTab: $selectedTab, tabs: [.group, .context])
    }
    .padding()
    .background(.colorBackgroundSurfaceless)
}
