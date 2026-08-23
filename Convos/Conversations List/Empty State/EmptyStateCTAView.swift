import SwiftUI

/// Scaffold for the new-user empty state: a headline, a subtitle, and the
/// primary CTA, centered in the space it is given.
///
/// Metrics are from Figma 8070:42419 - a 40pt headline on a tight 40pt line
/// height, a 17pt secondary subtitle 8pt below it, and the button 16pt below
/// that. Nothing here is fixed-size: an earlier version reserved slots so a
/// cycling mock area could not shift the button, and there is no longer
/// anything above the headline to cycle.
struct EmptyStateCTAView: View {
    /// Carries the design's own line break. The break is part of the
    /// composition rather than whatever the width happens to produce.
    let headline: String
    let subtitle: String
    let buttonTitle: String
    let onNewConvo: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            VStack(spacing: DesignConstants.Spacing.step2x) {
                headlineText
                subtitleText
            }
            ctaButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .background(.colorBackgroundSurfaceless)
        // The design centres this block on the screen. The shell insets this
        // view on both edges - the app pill is a `safeAreaInset(.top)`, the
        // tab bar sits at the bottom - so centring in what is left lands it
        // low. Spanning the full screen centres it where the design does,
        // without a per-device fudge factor. There is enough clearance either
        // side that nothing collides with the chrome.
        .ignoresSafeArea()
    }

    /// SF Pro regular 40pt on a tight 40pt line height with -1pt letter
    /// spacing, centered. `TightLineHeightText` owns the line-height + kern
    /// treatment; `Text` cannot pull a 40pt font onto a 40pt line.
    private var headlineText: some View {
        TightLineHeightText(
            text: headline,
            fontSize: Constant.headlineFontSize,
            lineHeight: Constant.headlineLineHeight,
            weight: .regular,
            textAlignment: .center
        )
    }

    private var subtitleText: some View {
        Text(subtitle)
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(.colorTextSecondary)
    }

    /// Deliberately not `.convosButtonStyle(.rounded)`: that style is a 15pt
    /// subheadline on 16pt horizontal padding, and the design calls for a
    /// 17pt label on 24pt with a fixed 52pt height.
    private var ctaButton: some View {
        Button(action: onNewConvo) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                // Larger than the label: the design draws the glyph at
                // roughly 20pt, not at the label's 17pt.
                Image(systemName: "plus")
                    .font(.system(size: Constant.buttonIconSize))
                Text(buttonTitle)
                    .font(.body)
            }
            .foregroundStyle(.colorTextPrimaryInverted)
            .padding(.horizontal, DesignConstants.Spacing.step6x)
            .frame(height: Constant.buttonHeight)
            .background(Capsule().fill(.colorLava))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("empty-state-new-convo-button")
    }

    private enum Constant {
        static let headlineFontSize: CGFloat = 40.0
        static let headlineLineHeight: CGFloat = 40.0
        /// Figma 8070:42552 sets the button's height rather than deriving it
        /// from the label's padding.
        static let buttonHeight: CGFloat = 52.0
        static let buttonIconSize: CGFloat = 20.0
    }
}

/// Chats-tab empty state.
struct ConversationsEmptyStateView: View {
    let onNewConvo: () -> Void

    var body: some View {
        EmptyStateCTAView(
            headline: "Groupchats\ncan be chaos",
            subtitle: "But here, things get done,\nand nothing gets lost.",
            buttonTitle: "Start a convo",
            onNewConvo: onNewConvo
        )
    }
}

#Preview("Conversations") {
    ConversationsEmptyStateView(onNewConvo: {})
}
