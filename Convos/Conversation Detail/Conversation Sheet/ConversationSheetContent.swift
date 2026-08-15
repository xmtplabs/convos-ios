import ConvosComposer
import os
import SwiftUI

/// TEMPORARY geometry probe for the sheet's layout work. Goes through os_log
/// because the app's `Log` writes to stdout, which the simulator's unified log
/// never captures. Read with:
/// `xcrun simctl spawn <udid> log show --last 5m --info --predicate 'subsystem == "org.convos.sheet"'`
enum ConversationSheetProbe {
    private static let log: OSLog = OSLog(subsystem: "org.convos.sheet", category: "inset")

    static func log(_ message: String) {
        os_log("%{public}@", log: log, type: .info, "[sheet-inset] \(message)")
    }
}

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
    TabBarContent: View,
    ContextMenuOverlay: View
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
    /// The message long-press menu, layered over everything else in the sheet.
    ///
    /// It belongs here rather than inside the transcript that raises it: the
    /// transcript is clipped to the detent's height, which would crop a
    /// screen-level menu, and it cannot go on the conversation behind the sheet
    /// either - the sheet is the topmost presentation and would cover it.
    @ViewBuilder let contextMenuOverlay: () -> ContextMenuOverlay

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // `.container` specifically, not all regions: the chrome has to clear
        // the home indicator's inset to rest at the physical bottom edge, but
        // the keyboard also arrives through the bottom safe area - ignoring
        // that too leaves the composer stranded behind it.
        //
        // On the container view rather than the chrome, because a ZStack child's
        // own `ignoresSafeArea` cannot push it outside the stack's frame, which
        // was already laid out inside the safe area.
        .ignoresSafeArea(.container, edges: .bottom)
        // Above the clip, so the long-press menu can cover the whole sheet
        // rather than being cropped to the transcript's frame.
        .overlay { contextMenuOverlay() }
        // TEMPORARY: the sheet's own content height, to tell apart "the detent
        // is too tall" from "the content is not filling the detent". Remove
        // with the rest of the geometry probes.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            ConversationSheetProbe.log("sheetContent height=\(height)")
        }
        .accessibilityIdentifier("conversation-bottom-sheet")
    }

    /// The selected transcript, filling the sheet at every detent.
    ///
    /// It stays visible even at `collapsed`, where the sheet is only as tall as
    /// the chrome: the chrome's blurred, fading backdrop covers it there, which
    /// reads better through a resize than cross-fading the whole transcript in
    /// and out. Hit-testing follows the detent regardless, so a message under
    /// the grabber cannot steal its drag.
    private var transcript: some View {
        transcriptContent()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .clipped()
            .allowsHitTesting(detent.showsTranscript)
    }

    /// Bar and tab bar - the part of the sheet present at every detent. Its
    /// measured height is what the `collapsed` detent resolves to.
    ///
    /// Ignores the bottom safe area, resting near the physical screen edge the
    /// way the native floating tab bar does, rather than sitting above the home
    /// indicator with a band of sheet beneath it.
    private var chrome: some View {
        VStack(spacing: Constant.contentSpacing) {
            barContent()
                // TEMPORARY: which part of the chrome owns the space above the
                // input bar. Remove with the rest of the geometry probes.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    ConversationSheetProbe.log("barContent height=\(height)")
                }
            tabBar()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    ConversationSheetProbe.log("tabBar height=\(height)")
                }
        }
        .padding(.top, Constant.contentTopPadding)
        .padding(.bottom, Constant.contentBottomPadding)
        .background { chromeBackdrop }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onChromeHeightChanged(height)
        }
    }
}

private extension ConversationSheetContent {
    /// Blur and tint behind the composer and tab bar, so transcript content
    /// scrolling underneath dissolves into the chrome instead of colliding with
    /// it.
    ///
    /// Both ramp in the same direction: nothing at the chrome's top edge, fully
    /// applied at the bottom. The tint ends on the sheet's own background
    /// colour, so the bottom of the chrome is indistinguishable from the sheet
    /// while the top stays clear enough to read a message through.
    var chromeBackdrop: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(fadeMask)
            tintFade
        }
        .allowsHitTesting(false)
    }

    /// Opaque at the bottom, clear at the top. Used as a mask, so it is the
    /// alpha channel that matters rather than the colour.
    var fadeMask: LinearGradient {
        LinearGradient(
            colors: [.clear, .black],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var tintFade: LinearGradient {
        LinearGradient(
            colors: [.clear, .colorBackgroundRaised],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// Hoisted out of the generic type: generic types cannot hold static stored
// properties.
private enum Constant {
    /// Short enough to keep up with a fast collapse, slow enough not to read
    /// as a pop.
    static let transcriptFadeDuration: Double = 0.2
    /// Gap between the bar and the tab bar (Figma gap-12). Horizontal insets
    /// stay with the bar content itself - the composer already carries the
    /// 16pt inset.
    static let contentSpacing: CGFloat = DesignConstants.Spacing.step3x
    /// Vertical space the system's drag indicator takes at the sheet's top
    /// edge, matching the metrics the design's own grabber used: 6pt in from
    /// the edge, 4pt tall.
    static let dragIndicatorAllowance: CGFloat = 10.0
    /// Clears the drag indicator and then leaves the same gap the bar and tab
    /// bar have between them, so at `collapsed` the run down the sheet is
    /// evenly spaced: grabber, gap, input bar, same gap, tab bar.
    static let contentTopPadding: CGFloat = dragIndicatorAllowance + contentSpacing
    static let contentBottomPadding: CGFloat = DesignConstants.Spacing.step4x
}
