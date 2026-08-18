import SwiftUI

/// Scaffold for the new-user empty state: an animated mock area on top, a
/// headline, a subtitle, and the primary CTA.
///
/// The slots are fixed-size (the mock area has a fixed height and the
/// headline reserves two lines) so the button never moves or resizes as the
/// slot contents cycle.
struct EmptyStateCTAView<MockContent: View>: View {
    let headline: String
    let subtitle: String
    let onNewConvo: () -> Void
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
            newConvoButton
                .padding(.top, DesignConstants.Spacing.step5x)
            Spacer(minLength: 0)
        }
        // The block sits step6x above true vertical center, per design.
        .offset(y: -DesignConstants.Spacing.step6x)
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

    private var newConvoButton: some View {
        Button(action: onNewConvo) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "plus")
                    .font(.callout)
                Text("New convo")
                    .font(.callout)
            }
        }
        .convosButtonStyle(.rounded(fullWidth: false, backgroundColor: .colorLava))
        .accessibilityIdentifier("empty-state-new-convo-button")
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
    }
}

/// Chats-tab empty state: the mock slot cycles through mock conversations
/// rendered as a larger pinned-conversation item, each animating in an
/// unread message.
struct ConversationsEmptyStateView: View {
    let onNewConvo: () -> Void

    var body: some View {
        EmptyStateCTAView(
            headline: "Private convos for everyday life",
            subtitle: "To use with friends and family",
            onNewConvo: onNewConvo
        ) {
            EmptyStateMockConversationCarousel(mocks: EmptyStateMocksProvider.shared.conversations)
        }
        .task {
            await EmptyStateMocksProvider.shared.refreshFromRemoteIfNeeded()
        }
    }
}

#Preview("Conversations") {
    ConversationsEmptyStateView(onNewConvo: {})
}
