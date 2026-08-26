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
    /// 36pt avatar inset by 8pt on every side. The presenter and this chrome
    /// use the same top inset and add nothing else, so this is the row's full
    /// height. Taking it for the 44pt of the back and share buttons beside it
    /// puts the control 8pt too high, overlapping the capsule.
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
    /// How far the scrim takes to fade from full strength to nothing.
    ///
    /// Figma (8007:27603) draws the wash as a 153pt band starting at the status
    /// bar's bottom edge. Starting it there puts the wash at roughly half
    /// strength by the time it reaches the segmented control - not enough to
    /// read the control against a transcript scrolling under it - so the ramp
    /// starts at the control's bottom instead (see `scrimHeight`).
    ///
    /// Moving the start down without shortening the ramp pushed the wash's end
    /// ~40pt past where it should sit, which reads as a wash running on too
    /// long below the control. The ramp is the knob rather than the hold:
    /// shortening the hold would take the strength out from under the control,
    /// which is the thing the deviation exists to protect.
    static let scrimRampLength: CGFloat = 113.0

    /// The whole chrome's height below the safe area, for a surface that
    /// reserves all of it.
    static let contentClearance: CGFloat =
        capsuleRowHeight + capsuleControlSpacing + controlHeight + controlBottomPadding

    /// Clearance for the Doc transcript identity pill when the segmented
    /// conversation control is intentionally absent.
    static let identityContentClearance: CGFloat = capsuleRowHeight + controlBottomPadding

    /// What the segmented control alone adds, for the transcripts.
    ///
    /// Deliberately not `contentClearance`. The chat transcript already keeps
    /// the capsule's row clear with a leading `.invite` / `.conversationInfo`
    /// cell (see `MessagesViewRepresentable.topContentInset`), so insetting by
    /// the full chrome counts that row twice and starts the messages well below
    /// where they belong.
    static let controlClearance: CGFloat =
        capsuleControlSpacing + controlHeight + controlBottomPadding

    /// The segmented control's bottom edge, measured from the screen's top.
    static func controlBottom(topSafeAreaInset: CGFloat) -> CGFloat {
        topSafeAreaInset + capsuleRowHeight + capsuleControlSpacing + controlHeight
    }

    static func chromeBottom(topSafeAreaInset: CGFloat, showsSegmentedControl: Bool) -> CGFloat {
        guard showsSegmentedControl else { return topSafeAreaInset + capsuleRowHeight }
        return controlBottom(topSafeAreaInset: topSafeAreaInset)
    }

    /// Everything the scrim covers: the chrome down to the control, plus the
    /// ramp that fades out below it.
    static func scrimHeight(topSafeAreaInset: CGFloat, showsSegmentedControl: Bool = true) -> CGFloat {
        chromeBottom(
            topSafeAreaInset: topSafeAreaInset,
            showsSegmentedControl: showsSegmentedControl
        ) + scrimRampLength
    }
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
        .ignoresSafeArea(edges: .top)
    }
}

/// The wash behind the conversation's top chrome: a blur with a white tint over
/// it, running from the screen's top edge (Figma 8007:27603 -
/// `backdrop-blur: 12` under a white-to-transparent gradient).
///
/// The blur is the substance and the tint only colours it. An opaque white over
/// the top would hide the blur entirely, which is what an earlier version did:
/// it read as a plain white gradient with a material behind it doing nothing.
///
/// Full strength down to the control's bottom edge, then one linear ramp to
/// nothing. Both halves matter. Holding through the control is what makes it
/// readable over a transcript - the design's ramp, started at the status bar, is
/// half gone by the time it reaches the control and the message underneath shows
/// straight through. Running the ramp over the design's full 153pt after that is
/// what stops it reading as an edge; a version that held the same distance but
/// fell over 60pt cut off mid-transcript.
///
/// A sibling of the chrome rather than its `.background`. The scrim is taller
/// than the chrome's own frame, and as a background that overflow is clipped -
/// measured on device, the wash stopped 69pt short of where it was asked to end.
struct ConversationChromeScrim: View {
    /// The window's top safe area, matching the value the chrome lays out to.
    var topSafeAreaInset: CGFloat
    var showsSegmentedControl: Bool = true

    var body: some View {
        let height: CGFloat = ConversationChromeMetrics.scrimHeight(
            topSafeAreaInset: topSafeAreaInset,
            showsSegmentedControl: showsSegmentedControl
        )
        let hold: CGFloat = holdFraction(in: height)
        let tintBase: Color = .colorBackgroundSurfaceless
        let tint: LinearGradient = LinearGradient(
            stops: [
                .init(color: tintBase, location: 0.0),
                .init(color: tintBase, location: hold),
                .init(color: tintBase.opacity(0), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        let fade: LinearGradient = LinearGradient(
            stops: [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: hold),
                .init(color: .black.opacity(0), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        return Rectangle()
            .fill(.ultraThinMaterial)
            .overlay { tint }
            .frame(height: height)
            .mask { fade }
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Where the wash stops holding and starts falling, as a fraction of its own
    /// height: the control's bottom edge.
    private func holdFraction(in height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0.0 }
        let chromeBottom: CGFloat = ConversationChromeMetrics.chromeBottom(
            topSafeAreaInset: topSafeAreaInset,
            showsSegmentedControl: showsSegmentedControl
        )
        return min(max(chromeBottom / height, 0.0), 1.0)
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
        ConversationChromeScrim(topSafeAreaInset: 59.0)
        ConversationTopChrome(topSafeAreaInset: 59.0) {
            ConversationSegmentedControl(selectedTab: .constant(.group))
        }
    }
    .background(.colorBackgroundSurfaceless)
}
