import ConvosComposer
import SwiftUI

/// Sheet metrics shared with the backing Home surface, which reserves bottom
/// clearance so its content is not hidden behind the resting sheet.
enum ConversationSheetMetrics {
    /// Rough intrinsic height of the sheet's chrome (composer + tab bar).
    /// Only a first-frame estimate and the seed for the `collapsed` detent;
    /// the chrome measures itself and publishes the real value.
    static let estimatedCollapsedHeight: CGFloat = 172.0
}

/// The contents of the conversation's presentation sheet: the selected
/// transcript above the selected tab's bar and the Group/Agent tab bar.
///
/// Everything about how big this is, and how it got that way, belongs to the
/// presentation - see `conversationSheetPresentation`. The system owns the
/// drag, the physics, interrupting a resize mid-flight, the handoff between
/// scrolling the transcript and resizing the sheet, the grabber, and the
/// pass-through that keeps the Home behind it touchable. The sheet also paints
/// its own surface and corners.
///
/// All this view does is fill the height the current detent gives it: the
/// chrome takes its intrinsic height and the transcript takes the rest, which
/// is nothing at all at `collapsed`.
struct ConversationSheetContent<
    TranscriptContent: View,
    BarContent: View,
    TabBarContent: View
>: View {
    /// The size the sheet is resting at, which decides whether the transcript
    /// is showing at all.
    var detent: ConversationSheetDetent
    /// Fired with the chrome's measured height. The host publishes it into the
    /// environment, where the `collapsed` and `compact` detents read it.
    var onChromeHeightChanged: (CGFloat) -> Void = { _ in }
    /// The selected transcript, given whatever height the detent leaves above
    /// the chrome and clipped to it.
    @ViewBuilder let transcriptContent: () -> TranscriptContent
    /// The selected tab's bar, e.g. the group or agent composer.
    @ViewBuilder let barContent: () -> BarContent
    @ViewBuilder let tabBar: () -> TabBarContent

    /// Siblings in a ZStack rather than a `safeAreaInset` or a `VStack`, and
    /// the distinction is what makes messages pass under the chrome:
    ///
    /// - A `VStack` gives the chrome its own row, so the transcript stops dead
    ///   at the composer's top edge.
    /// - `safeAreaInset` reserves layout space too - it shrinks the transcript
    ///   the same way - and its inset does not reach the hosted collection
    ///   view's `safeAreaInsets`, so it buys nothing in exchange.
    /// - As ZStack siblings the transcript takes the whole sheet and draws
    ///   beneath the chrome (it ignores the safe area internally), while the
    ///   chrome respects it and stays clear of the home indicator.
    ///
    /// The transcript's own bottom content inset is what keeps its newest
    /// message clear of the chrome; the host supplies it from
    /// `onChromeHeightChanged`.
    var body: some View {
        ZStack(alignment: .bottom) {
            transcript
            chrome
        }
        .accessibilityIdentifier("conversation-bottom-sheet")
    }

    /// The selected transcript, filling the sheet and faded out at
    /// `collapsed`.
    ///
    /// Collapsed still gives it the sheet's full height - which is the chrome's
    /// height - so it sits entirely behind the chrome. Fading it and dropping
    /// hit-testing keeps it from painting a sliver through the sheet's top edge
    /// or holding a touch target under the grabber. It stays mounted rather
    /// than torn down so scroll position survives.
    private var transcript: some View {
        let isShowing: Bool = detent.showsTranscript
        return transcriptContent()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .clipped()
            .opacity(isShowing ? 1 : 0)
            .allowsHitTesting(isShowing)
            .animation(.easeInOut(duration: Constant.transcriptFadeDuration), value: isShowing)
    }

    /// Bar and tab bar - the part of the sheet present at every detent. Its
    /// measured height is what the `collapsed` detent resolves to.
    private var chrome: some View {
        VStack(spacing: Constant.contentSpacing) {
            barContent()
            tabBar()
        }
        .padding(.top, Constant.contentTopPadding)
        .padding(.bottom, Constant.contentBottomPadding)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onChromeHeightChanged(height)
        }
    }
}

// Hoisted out of the generic type: generic types cannot hold static stored
// properties.
private enum Constant {
    /// Short enough to keep up with a fast collapse, slow enough not to read
    /// as a pop.
    static let transcriptFadeDuration: Double = 0.2
    /// Sheet chrome: 16pt padding with a 12pt gap between the bar and the tab
    /// bar (Figma p-16 / gap-12). Horizontal insets stay with the bar content
    /// itself - the composer already carries the 16pt inset.
    static let contentSpacing: CGFloat = DesignConstants.Spacing.step3x
    static let contentTopPadding: CGFloat = DesignConstants.Spacing.step4x
    static let contentBottomPadding: CGFloat = DesignConstants.Spacing.step4x
}
