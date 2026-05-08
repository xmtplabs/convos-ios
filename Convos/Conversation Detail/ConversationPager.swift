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
        HStack(spacing: DesignConstants.Spacing.step2x) {
            ForEach(ConversationPagerPage.allCases) { page in
                let isSelected: Bool = page == selectedPage
                let action = {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedPage = page
                    }
                }
                Button(action: action) {
                    Capsule()
                        .fill(isSelected ? Color.colorTextPrimary : Color.colorTextSecondary.opacity(0.3))
                        .frame(width: isSelected ? 18.0 : 8.0, height: 8.0)
                        .animation(.easeInOut(duration: 0.2), value: isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(for: page))
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step2x)
        .frame(height: 24.0)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityIdentifier("conversation-pager-dots")
    }

    private func label(for page: ConversationPagerPage) -> String {
        switch page {
        case .messages: return "Messages"
        case .stuff: return "Stuff"
        }
    }
}
