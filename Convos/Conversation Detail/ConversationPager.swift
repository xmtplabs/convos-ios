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
    let showsPageDots: Bool
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
            .introspect(.scrollView, on: .iOS(.v26)) { (scrollView: UIScrollView) in
                scrollView.bounces = false
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsPageDots {
                ConversationPagerDots(selectedPage: $selectedPage)
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
        case .stuff: return "Stuff"
        }
    }
}
