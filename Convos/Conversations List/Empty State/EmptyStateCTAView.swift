import SwiftUI

/// Shared scaffold for the new-user empty states on the Chats and Things
/// tabs: an animated mock area on top, a headline, a subtitle, the
/// "Make an agent" CTA, and an "Explore agents in Contacts" link.
///
/// Both tabs render this exact structure with fixed-size slots (the mock
/// area has a fixed height and the headline reserves two lines), so
/// switching tabs never moves or resizes the button or any other
/// component; only the slot contents and copy change.
struct EmptyStateCTAView<MockContent: View>: View {
    let headline: String
    let subtitle: String
    let onMakeAgent: () -> Void
    var onExploreAgents: (() -> Void)?
    @ViewBuilder var mockContent: () -> MockContent

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            // Bottom-aligned in the fixed slot so the gap between the mock
            // and the headline is exactly the step4x below, per the design.
            mockContent()
                .frame(height: Constant.mockSlotHeight, alignment: .bottom)
            headlineText
                .padding(.top, DesignConstants.Spacing.step4x)
            subtitleText
                .padding(.top, DesignConstants.Spacing.step2x)
            makeAgentButton
                .padding(.top, DesignConstants.Spacing.step5x)
            exploreAgentsButton
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .background(.colorBackgroundSurfaceless)
    }

    /// Design spec: SF Pro regular 40pt on a tight 40pt line height with
    /// -1pt letter spacing, centered. `TightLineHeightText` owns the
    /// line-height + kern treatment; the fixed two-line frame keeps the
    /// components below at identical positions on both tabs.
    private var headlineText: some View {
        TightLineHeightText(
            text: headline,
            fontSize: Constant.headlineFontSize,
            lineHeight: Constant.headlineLineHeight,
            weight: .regular,
            textAlignment: .center
        )
        .frame(height: Constant.headlineHeight, alignment: .center)
    }

    private var subtitleText: some View {
        Text(subtitle)
            .font(.body)
            .multilineTextAlignment(.center)
            .lineLimit(1, reservesSpace: true)
            .foregroundStyle(.colorTextSecondary)
    }

    private var makeAgentButton: some View {
        Button(action: onMakeAgent) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image("addAgentIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Constant.agentIconSize, height: Constant.agentIconSize)
                Text("Make an agent")
                    .font(.callout)
            }
        }
        .convosButtonStyle(.rounded(fullWidth: false, backgroundColor: .colorLava))
        .accessibilityIdentifier("empty-state-make-agent-button")
    }

    @ViewBuilder
    private var exploreAgentsButton: some View {
        if let onExploreAgents {
            let action = { onExploreAgents() }
            Button(action: action) {
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    Text("Explore agents in Contacts")
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.colorTextTertiary)
                }
            }
            .convosButtonStyle(.text)
            .accessibilityIdentifier("empty-state-explore-agents-button")
        }
    }

    // Computed because generic types do not support static stored
    // properties.
    private enum Constant {
        /// Matches the tallest visible mock (the 160pt thing card plus its
        /// conversation-name caption; the conversation mock is a few points
        /// shorter) so the equal spacers above and below center the visible
        /// content, with no phantom slot headroom pushing the block down.
        static var mockSlotHeight: CGFloat { 186.0 }
        static var headlineFontSize: CGFloat { 40.0 }
        static var headlineLineHeight: CGFloat { 40.0 }
        /// Two lines at the tight 40pt line height.
        static var headlineHeight: CGFloat { 80.0 }
        static var agentIconSize: CGFloat { 18.0 }
    }
}

/// Chats-tab empty state: the mock slot cycles through mock conversations
/// rendered as a larger pinned-conversation item, each animating in an
/// unread message.
struct ConversationsEmptyStateView: View {
    let onMakeAgent: () -> Void
    var onExploreAgents: (() -> Void)?

    var body: some View {
        EmptyStateCTAView(
            headline: "Make little agents for everyday life",
            subtitle: "To use with friends and family",
            onMakeAgent: onMakeAgent,
            onExploreAgents: onExploreAgents
        ) {
            EmptyStateMockConversationCarousel(mocks: EmptyStateMocksProvider.shared.conversations)
        }
        .task {
            await EmptyStateMocksProvider.shared.refreshFromRemoteIfNeeded()
        }
    }
}

/// Things-tab empty state: the mock slot cycles through mock thing cells
/// whose previews are rendered from real example HTML files.
struct ThingsEmptyStateView: View {
    let onMakeAgent: () -> Void
    var onExploreAgents: (() -> Void)?

    var body: some View {
        EmptyStateCTAView(
            headline: "Agents make things for the chat",
            subtitle: "Plans, lists, notes, apps and more",
            onMakeAgent: onMakeAgent,
            onExploreAgents: onExploreAgents
        ) {
            EmptyStateMockThingCarousel(mocks: EmptyStateMocksProvider.shared.things)
        }
        .task {
            await EmptyStateMocksProvider.shared.refreshFromRemoteIfNeeded()
        }
    }
}

#Preview("Conversations") {
    ConversationsEmptyStateView(onMakeAgent: {}, onExploreAgents: {})
}

#Preview("Things") {
    ThingsEmptyStateView(onMakeAgent: {}, onExploreAgents: {})
}
