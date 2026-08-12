import ConvosComposer
import SwiftUI

/// The conversation sheet's tab bar: Desktop | Group | Agent pills that
/// drive the selected conversation surface. Modeled on the system tab bar's
/// equal-width icon-over-label items; the selected pill gets a subtle
/// capsule highlight.
struct ConversationTabBar: View {
    @Binding var selectedTab: ConversationTab
    /// Tabs to render, in order. The full set by default; hosts may trim it
    /// (e.g. a draft conversation with no desktop yet).
    var tabs: [ConversationTab] = ConversationTab.allCases

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            ForEach(tabs) { tab in
                pill(for: tab)
            }
        }
        .padding(.horizontal, Constant.barPaddingHorizontal)
        .accessibilityIdentifier("conversation-tab-bar")
    }

    private func pill(for tab: ConversationTab) -> some View {
        let isSelected: Bool = tab == selectedTab
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: Constant.glyphLabelSpacing) {
                glyph(for: tab)
                Text(tab.title)
                    .font(.system(size: Constant.labelPointSize, weight: .medium))
                    .foregroundStyle(Color.colorTextPrimary)
            }
            .frame(width: Constant.pillWidth)
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.primary.opacity(Constant.selectedFillOpacity))
                }
            }
            .contentShape(.capsule)
            .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("conversation-tab-\(tab.rawValue)")
    }

    @ViewBuilder
    private func glyph(for tab: ConversationTab) -> some View {
        switch tab {
        case .desktop:
            symbolGlyph("macwindow")
        case .group:
            symbolGlyph("message.fill")
        case .agent:
            agentGlyph
        }
    }

    private func symbolGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: Constant.iconPointSize, weight: .medium))
            .foregroundStyle(Color.colorTextPrimary)
            .frame(height: Constant.iconSlotHeight)
    }

    /// The agent glyph: the shared `addAgentIcon` asset in a badge circle,
    /// sized to sit in the same icon slot as the symbol pills.
    private var agentGlyph: some View {
        Image("addAgentIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.background)
            .frame(width: Constant.agentGlyphSize, height: Constant.agentGlyphSize)
            .frame(width: Constant.agentBadgeSize, height: Constant.agentBadgeSize)
            .background(Color.colorTextPrimary, in: .circle)
            .frame(height: Constant.iconSlotHeight)
    }

    private enum Constant {
        /// Fill of the selected pill's capsule highlight; `Color.primary`
        /// based so it lightens the pill on the dark agent surface and tints
        /// it on the light group surface.
        static let selectedFillOpacity: Double = 0.08
        static let barPaddingHorizontal: CGFloat = DesignConstants.Spacing.stepX
        /// Fixed pill width, mirroring the equal-width items of the system
        /// tab bar so the tabs read as uniform slots regardless of label.
        static let pillWidth: CGFloat = 90.0
        /// Metrics mirroring the system tab bar items on the home screen:
        /// ~18pt medium symbols over 10pt medium labels, tightly stacked.
        static let iconPointSize: CGFloat = 18.0
        static let labelPointSize: CGFloat = 10.0
        /// Fixed icon slot so the symbols and the agent badge baseline-align
        /// their labels across pills.
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
