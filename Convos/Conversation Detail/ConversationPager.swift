import ConvosCore
import SwiftUI
import SwiftUIIntrospect

enum ConversationPagerPage: Hashable, Identifiable {
    case messages
    /// The user's private DM with the conversation's agent, rendered as a
    /// page of the origin conversation rather than a separate chat.
    case agentDm(agentInboxId: String)
    /// The single Agent tab used by the Group/Agent switcher: one page that
    /// hosts whichever agent DM is selected (see `AgentPageView`), rather
    /// than one `.agentDm` page per agent.
    case agent
    case things

    var id: String {
        switch self {
        case .messages: return "messages"
        case .agentDm(let agentInboxId): return "agent-dm-\(agentInboxId)"
        case .agent: return "agent"
        case .things: return "things"
        }
    }
}

struct ConversationPager<MessagesPage: View, AgentDmPage: View, AgentPage: View, ThingsPage: View>: View {
    @Binding var selectedPage: ConversationPagerPage
    /// Ordered pages to render: `.messages` first, an `.agentDm` page when
    /// the conversation has a DM-able agent, `.things` last. Built by
    /// `ConversationView`.
    let pages: [ConversationPagerPage]
    /// Whether the dots are mounted at all. Drives the `safeAreaInset`
    /// itself, so flipping this resizes the pager content - only set it
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
    /// the message long-press context menu is presented - without it the
    /// user can drag past the menu into another page mid-interaction.
    var scrollingDisabled: Bool = false
    /// Desktop drawers change width while their collapsed edge inset morphs
    /// away. Keep all pages mounted in a stationary stack there so that width
    /// changes cannot strand a horizontal pager between two pages.
    var usesStationaryPages: Bool = false
    @ViewBuilder let messagesPage: () -> MessagesPage
    @ViewBuilder let agentDmPage: (String) -> AgentDmPage
    @ViewBuilder let agentPage: () -> AgentPage
    @ViewBuilder let thingsPage: () -> ThingsPage

    var body: some View {
        GeometryReader { proxy in
            Group {
                if usesStationaryPages {
                    ZStack {
                        ForEach(pages) { page in
                            let isSelected: Bool = page == selectedPage
                            pageContent(for: page)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .opacity(isSelected ? 1 : 0)
                                .allowsHitTesting(isSelected)
                                .accessibilityHidden(!isSelected)
                                .zIndex(isSelected ? 1 : 0)
                        }
                    }
                } else {
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
        case .agent:
            agentPage()
        case .things:
            thingsPage()
        }
    }
}

private struct ConversationPagerDots: View {
    @Binding var selectedPage: ConversationPagerPage
    let pages: [ConversationPagerPage]
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 6.0) {
            ForEach(pages) { page in
                let isSelected: Bool = page == selectedPage
                let action = {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedPage = page
                    }
                }
                Button(action: action) {
                    indicator(for: page, isSelected: isSelected)
                        .animation(.easeInOut(duration: 0.2), value: isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(for: page))
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step2x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityIdentifier("conversation-pager-dots")
    }

    /// The per-page indicator glyph. The agent-DM page reads as a small "A"
    /// (mirroring the agent badge elsewhere) instead of a plain dot; the other
    /// pages keep their shaped dots. Colored by selection like every dot.
    @ViewBuilder
    private func indicator(for page: ConversationPagerPage, isSelected: Bool) -> some View {
        // The active indicator is pure white in dark mode (the DM page forces
        // dark, so the selected "A" always lands here); light mode keeps the
        // fill token. Inactive items stay on the tertiary fill either way.
        let selectedColor: Color = colorScheme == .dark ? .white : .colorFillSecondary
        let color: Color = isSelected ? selectedColor : .colorFillTertiary
        switch page {
        case .agentDm, .agent:
            // SF Pro Bold 11pt in an 11pt box, per Figma (node 6905-10624).
            Text("A")
                .font(.system(size: 11.0, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 11.0, height: 11.0)
        default:
            pageShape(for: page)
                .fill(color)
                .frame(width: 8.0, height: 8.0)
        }
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
        case .agentDm, .agent:
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
        case .agentDm, .agent: return "Agent chat"
        case .things: return "Things"
        }
    }
}
