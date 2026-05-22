import SwiftUI

/// Custom replacement for SwiftUI's built-in tab bar. We own the chrome
/// so we can synchronize its hide/show animation with the navigation push
/// when a conversation is selected — and so the builder bar above it can
/// share a `GlassEffectContainer` with the tab pills for a clean morph.
///
/// Layout matches the design:
///
/// ```
/// [   Chats |  Stuff   ]        ( 🔍 )
/// ```
///
/// - Two glass capsule pills (Chats, Stuff) in one capsule container,
///   with a matched-geometry selected-pill background that slides
///   between them.
/// - A standalone glass circle search button trailing.
struct ConvosTabBar: View {
    @Binding var activeTab: ConvosTab

    @Namespace private var selectionNamespace: Namespace.ID

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            tabPills
            Spacer(minLength: 0)
            searchButton
        }
    }

    private var tabPills: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                tabPill(for: .chats)
                tabPill(for: .stuff)
            }
            .padding(Constant.outerPadding)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    private func tabPill(for tab: ConvosTab) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) {
                activeTab = tab
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 22, weight: .regular))
                Text(tab.title)
                    .font(.system(size: 10, weight: .bold))
            }
            .padding(.top, 6)
            .padding(.bottom, 7)
            .padding(.horizontal, 8)
            .frame(width: Constant.tabPillWidth, height: Constant.tabPillHeight)
            .foregroundStyle(activeTab == tab ? Color.colorBlue : Color.colorTextPrimary)
            .background {
                if activeTab == tab {
                    Color.clear
                        .glassEffect(
                            .regular.tint(Color.colorFillTertiary.opacity(0.25)).interactive(),
                            in: .capsule
                        )
                        .matchedGeometryEffect(id: Constant.selectionId, in: selectionNamespace)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier("convos-tab-\(tab)")
    }

    private var searchButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) {
                activeTab = .search
            }
        } label: {
            Image(systemName: ConvosTab.search.symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(activeTab == .search ? Color.colorBlue : Color.colorTextPrimary)
                .frame(width: Constant.searchButtonSize, height: Constant.searchButtonSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Search")
        .accessibilityIdentifier("convos-tab-search")
    }

    private enum Constant {
        static let selectionId: String = "convos-tab-bar-selection"
        static let outerPadding: CGFloat = 4.0
        static let searchButtonSize: CGFloat = 56.0
        static let tabPillWidth: CGFloat = 102.0
        static let tabPillHeight: CGFloat = 54.0
    }
}

#Preview("Chats active") {
    @Previewable @State var activeTab: ConvosTab = .chats
    ConvosTabBar(activeTab: $activeTab)
        .padding()
        .background(Color.colorBackgroundSurfaceless)
}

#Preview("Stuff active") {
    @Previewable @State var activeTab: ConvosTab = .stuff
    ConvosTabBar(activeTab: $activeTab)
        .padding()
        .background(Color.colorBackgroundSurfaceless)
}
