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

    var body: some View {
        VStack(spacing: 0) {
            transcript
            chrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .accessibilityIdentifier("conversation-bottom-sheet")
    }

    /// The selected transcript, faded out at `collapsed`.
    ///
    /// Collapsed leaves it a zero-height slot, but a UIKit collection view
    /// laying out against that still paints a sliver of its top row through the
    /// sheet's own top edge - and, worse, keeps a touch target there, right
    /// where the grabber is. Fading it and dropping hit-testing settles both.
    /// It stays mounted rather than torn down so scroll position survives.
    private var transcript: some View {
        let isShowing: Bool = detent.showsTranscript
        return transcriptContent()
            .frame(maxHeight: .infinity, alignment: .bottom)
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
