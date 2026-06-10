import ConvosCore
import SwiftUI
import SwiftUIIntrospect

enum ConversationPagerPage: Int, CaseIterable, Identifiable {
    case messages
    case stuff

    var id: Int { rawValue }
}

struct ConversationPager<MessagesPage: View, StuffPage: View>: View {
    @Binding var selectedPage: ConversationPagerPage
    /// Whether the dots are mounted at all. Drives the `safeAreaInset`
    /// itself, so flipping this resizes the pager content — only set it
    /// based on keyboard presence, which already animates via the
    /// system. Don't piggyback context-menu-driven hiding on this flag
    /// or the bottom bar's own fade-out animation has to compete with a
    /// layout reflow inside MessagesView.
    let showsPageDots: Bool
    /// Hides the dots in-place when true (opacity + scale only, layout
    /// space preserved). Used while the long-press context menu is
    /// presented so the dots fade out without resizing anything around
    /// them.
    var dotsHidden: Bool = false
    /// When true, horizontal paging between `messages` and `stuff` is
    /// blocked. Used while the message long-press context menu is
    /// presented — without it the user can drag past the menu into the
    /// stuff page mid-interaction.
    var scrollingDisabled: Bool = false
    @ViewBuilder let messagesPage: () -> MessagesPage
    @ViewBuilder let stuffPage: () -> StuffPage

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    messagesPage()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .id(ConversationPagerPage.messages)

                    stuffPage()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .id(ConversationPagerPage.stuff)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: Binding(
                get: { selectedPage },
                set: { newValue in
                    if let newValue { selectedPage = newValue }
                }
            ))
            .scrollDisabled(scrollingDisabled)
            .introspect(.scrollView, on: .iOS(.v26)) { (scrollView: UIScrollView) in
                scrollView.bounces = false
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsPageDots {
                ConversationPagerDots(selectedPage: $selectedPage)
                    .opacity(dotsHidden ? 0 : 1)
                    .scaleEffect(dotsHidden ? 0.85 : 1)
                    .allowsHitTesting(!dotsHidden)
                    .animation(.spring(response: 0.3, dampingFraction: 0.9), value: dotsHidden)
            }
        }
    }
}

private struct ConversationPagerDots: View {
    @Binding var selectedPage: ConversationPagerPage

    var body: some View {
        HStack(spacing: 10.0) {
            ForEach(ConversationPagerPage.allCases) { page in
                let isSelected: Bool = page == selectedPage
                let action = {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedPage = page
                    }
                }
                Button(action: action) {
                    pageShape(for: page)
                        .fill(isSelected ? Color.colorFillSecondary : Color.colorFillTertiary)
                        .frame(width: 8.0, height: 8.0)
                        .animation(.easeInOut(duration: 0.2), value: isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(for: page))
            }
        }
        .padding(.horizontal, 10.0)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityIdentifier("conversation-pager-dots")
    }

    private func pageShape(for page: ConversationPagerPage) -> UnevenRoundedRectangle {
        switch page {
        case .messages:
            return UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 8.0,
                bottomLeading: 2.0,
                bottomTrailing: 8.0,
                topTrailing: 8.0
            ))
        case .stuff:
            return UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 2.0,
                bottomLeading: 2.0,
                bottomTrailing: 2.0,
                topTrailing: 2.0
            ))
        }
    }

    private func label(for page: ConversationPagerPage) -> String {
        switch page {
        case .messages: return "Messages"
        case .stuff: return "Things"
        }
    }
}
