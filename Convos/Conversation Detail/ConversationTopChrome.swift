import SwiftUI

/// The metrics the conversation's floating top chrome is built from, and the
/// clearance every page beneath it reserves.
///
/// Arithmetic rather than measurement, deliberately. Every piece here is a
/// fixed size, and a measured height would have to travel back up into the
/// state the pages read - a write-per-layout-pass feedback loop that the sheet
/// this replaces spent a lot of code defending against. Nothing in the chrome
/// resizes, so there is nothing to measure.
enum ConversationChromeMetrics {
    /// The conversation's title capsule, which `ConversationPresenter` draws as
    /// an overlay above this view rather than inside it. The chrome reserves its
    /// height so the segmented control lands underneath it instead of behind it.
    ///
    /// Derived from `ConversationToolbarButton` rather than guessed at: it is a
    /// 36pt avatar inset by 8pt on every side. The presenter pads the whole
    /// capsule down by the top safe area and adds nothing else, so this is the
    /// row's full height. Taking it for the 44pt of the back and share buttons
    /// beside it puts the control 8pt too high, overlapping the capsule.
    static let capsuleRowHeight: CGFloat =
        capsuleAvatarSize + (DesignConstants.Spacing.step2x * 2)
    /// The avatar inside the title capsule; see `ConversationToolbarButton`.
    private static let capsuleAvatarSize: CGFloat = 36.0
    /// Gap between the capsule and the segmented control (Figma 8007:27603,
    /// gap-8).
    static let capsuleControlSpacing: CGFloat = DesignConstants.Spacing.step2x
    /// The segmented control's own height: a 15pt label on a 20pt line with 6pt
    /// above and below (Figma 8007:27596).
    static let controlHeight: CGFloat = 32.0
    /// Space below the control before a page's content may start.
    static let controlBottomPadding: CGFloat = DesignConstants.Spacing.step3x
    /// How far the scrim fades past the content it sits behind, so a transcript
    /// scrolling under it dissolves rather than meeting a hard edge.
    static let scrimFadeDistance: CGFloat = DesignConstants.Spacing.step12x

    /// The whole chrome's height below the safe area, for a surface that
    /// reserves all of it.
    static let contentClearance: CGFloat =
        capsuleRowHeight + capsuleControlSpacing + controlHeight + controlBottomPadding

    /// What the segmented control alone adds, for the transcripts.
    ///
    /// Deliberately not `contentClearance`. The chat transcript already keeps
    /// the capsule's row clear with a leading `.invite` / `.conversationInfo`
    /// cell (see `MessagesViewRepresentable.topContentInset`), so insetting by
    /// the full chrome counts that row twice and starts the messages well below
    /// where they belong.
    static let controlClearance: CGFloat =
        capsuleControlSpacing + controlHeight + controlBottomPadding
}

/// The conversation's floating top chrome: the segmented control on a scrim
/// that fades downward, sitting over whichever page is selected.
///
/// The scrim is what makes the control readable over a scrolling transcript or
/// a Space page whose colors this view cannot know. It fades out rather than
/// ending, so content passing under it is never cut by a line.
struct ConversationTopChrome<Control: View>: View {
    /// The window's top safe area. Passed in rather than read here so the value
    /// matches the one the pages inset by.
    var topSafeAreaInset: CGFloat
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(spacing: ConversationChromeMetrics.capsuleControlSpacing) {
            // The capsule itself is drawn over this view by its own host, so
            // only its height is reserved here - and the reservation must not
            // take the taps meant for it. `Color.clear` is hit-testable, so
            // without this the chrome sits invisibly on top of the capsule and
            // swallows every tap on it.
            Color.clear
                .frame(height: ConversationChromeMetrics.capsuleRowHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            control()
                .frame(height: ConversationChromeMetrics.controlHeight)
        }
        .padding(.top, topSafeAreaInset)
        .padding(.bottom, ConversationChromeMetrics.controlBottomPadding)
        .frame(maxWidth: .infinity)
        .background { scrim }
        .ignoresSafeArea(edges: .top)
    }

    /// White at the top fading to nothing, with a matching fade on the blur
    /// behind it (Figma 8007:27603: a top-down gradient over a 12pt backdrop
    /// blur). Both are masked by the same ramp so they disappear together.
    private var scrim: some View {
        let fade: LinearGradient = LinearGradient(
            colors: [Color.black, Color.black.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        return ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Rectangle()
                .fill(Color.colorBackgroundSurfaceless)
        }
        .mask { fade }
        .padding(.bottom, -ConversationChromeMetrics.scrimFadeDistance)
        .allowsHitTesting(false)
    }
}

#Preview {
    ZStack(alignment: .top) {
        ScrollView {
            VStack(spacing: 12.0) {
                ForEach(0..<30, id: \.self) { index in
                    Text("Message \(index)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.colorFillMinimal, in: .rect(cornerRadius: 16.0))
                }
            }
            .padding()
        }
        ConversationTopChrome(topSafeAreaInset: 59.0) {
            ConversationSegmentedControl(selectedTab: .constant(.group))
        }
    }
    .background(.colorBackgroundSurfaceless)
}
