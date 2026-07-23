import ConvosCore
import SwiftUI
import SwiftUIIntrospect

enum ConversationPagerPage: Hashable, Identifiable {
    case messages
    /// The user's private DM with the conversation's agent, rendered as a
    /// page of the origin conversation rather than a separate chat.
    case agentDm(agentInboxId: String)
    case things

    var id: String {
        switch self {
        case .messages: return "messages"
        case .agentDm(let agentInboxId): return "agent-dm-\(agentInboxId)"
        case .things: return "things"
        }
    }
}

struct ConversationPager<MessagesPage: View, AgentDmPage: View, ThingsPage: View>: View {
    @Binding var selectedPage: ConversationPagerPage
    /// Ordered pages to render: `.messages` first, an `.agentDm` page when
    /// the conversation has a DM-able agent, `.things` last. Built by
    /// `ConversationView`.
    let pages: [ConversationPagerPage]
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
    /// When true, horizontal paging between pages is blocked. Used while
    /// the message long-press context menu is presented — without it the
    /// user can drag past the menu into another page mid-interaction.
    var scrollingDisabled: Bool = false
    @ViewBuilder let messagesPage: () -> MessagesPage
    @ViewBuilder let agentDmPage: (String) -> AgentDmPage
    @ViewBuilder let thingsPage: () -> ThingsPage

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(pages) { page in
                        pageContent(for: page)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .id(page)
                    }
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
                ConversationPagerDots(selectedPage: $selectedPage, pages: pages)
                    .opacity(dotsHidden ? 0 : 1)
                    .scaleEffect(dotsHidden ? 0.85 : 1)
                    .allowsHitTesting(!dotsHidden)
                    .animation(.spring(response: 0.3, dampingFraction: 0.9), value: dotsHidden)
            }
        }
    }

    @ViewBuilder
    private func pageContent(for page: ConversationPagerPage) -> some View {
        switch page {
        case .messages:
            messagesPage()
        case .agentDm(let agentInboxId):
            agentDmPage(agentInboxId)
        case .things:
            thingsPage()
        }
    }
}

private struct ConversationPagerDots: View {
    @Binding var selectedPage: ConversationPagerPage
    let pages: [ConversationPagerPage]

    var body: some View {
        HStack(spacing: 10.0) {
            ForEach(pages) { page in
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
        case .agentDm:
            return UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 8.0,
                bottomLeading: 8.0,
                bottomTrailing: 8.0,
                topTrailing: 8.0
            ))
        case .things:
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
        case .agentDm: return "Agent chat"
        case .things: return "Things"
        }
    }
}
