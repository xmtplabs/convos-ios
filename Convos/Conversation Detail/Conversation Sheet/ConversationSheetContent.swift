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

extension View {
    /// TEMPORARY layout outline for the sheet's geometry work, so each layer's
    /// real bounds are visible on screen. Remove with the rest of the probes.
    func debugBorder(_ color: Color) -> some View {
        overlay {
            Rectangle()
                .strokeBorder(color, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

private struct TranscriptClippedTopOverflowKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How much of a transcript's top its host clips away, for a host that hands
    /// the transcript a taller frame than it shows. Travels through the
    /// environment because the transcripts are built by the conversation and
    /// handed to the sheet as content, so the sheet - the only party that knows
    /// what it is clipping - cannot pass it as an argument.
    ///
    /// See `MessagesViewController.clippedTopOverflow` for what it does.
    var transcriptClippedTopOverflow: CGFloat {
        get { self[TranscriptClippedTopOverflowKey.self] }
        set { self[TranscriptClippedTopOverflowKey.self] = newValue }
    }
}

/// How the sheet's chrome is put together, and the heights that follow from it.
///
/// Shared rather than private to the view because three other parties need the
/// same arithmetic: the `collapsed` detent, the transcript's bottom clearance,
/// and the backing Home surface, which reserves bottom clearance so its content
/// is not hidden behind the resting sheet.
enum ConversationSheetMetrics {
    /// Gap between the bar and the tab bar (Figma gap-12). Horizontal insets
    /// stay with the bar content itself - the composer already carries the
    /// 16pt inset.
    static let chromeContentSpacing: CGFloat = DesignConstants.Spacing.step3x
    /// Vertical space the system's drag indicator takes at the sheet's top
    /// edge, matching the metrics the design's own grabber used: 6pt in from
    /// the edge, 4pt tall.
    static let dragIndicatorAllowance: CGFloat = 10.0
    static let chromeBottomPadding: CGFloat = DesignConstants.Spacing.step4x

    /// Rough intrinsic height of the chrome's bars (composer plus tab bar and
    /// the gap between them). Only a first-frame estimate; the chrome measures
    /// itself and publishes the real value.
    static let estimatedBarsHeight: CGFloat = 123.0

    /// `collapsedChromeHeight` for the estimate above - the first-frame resting
    /// height, for surfaces that reserve clearance before the chrome has
    /// measured itself.
    static var estimatedRestingHeight: CGFloat {
        collapsedChromeHeight(barsHeight: estimatedBarsHeight)
    }

    /// Space above the input bar, which is the one measurement that depends on
    /// where the sheet is resting.
    ///
    /// At `collapsed` the sheet's top edge *is* the chrome's top edge, so the
    /// drag indicator's band has to be cleared before the bar can sit at the
    /// same 12pt gap the bar and tab bar have between them. At every larger
    /// detent the indicator is up at the sheet's own top edge and the bar wants
    /// nothing but the gap - holding the band there just pushes the transcript
    /// 10pt further from the bar it should be resting against.
    static func chromeTopPadding(for detent: ConversationSheetDetent) -> CGFloat {
        guard detent == .collapsed else { return chromeContentSpacing }
        return dragIndicatorAllowance + chromeContentSpacing
    }

    /// The chrome's frame height, which is also what the transcript keeps clear
    /// at its bottom.
    static func chromeHeight(barsHeight: CGFloat, detent: ConversationSheetDetent) -> CGFloat {
        barsHeight + chromeTopPadding(for: detent) + chromeBottomPadding
    }

    /// The height the sheet rests at when collapsed: what the `collapsed`
    /// detent resolves to, and the clearance the Home behind it reserves.
    ///
    /// Deliberately the collapsed geometry rather than the chrome's current
    /// height. A detent that tracked the current height would shed the drag
    /// indicator's band on the way up and then, once the sheet had settled back
    /// at `collapsed` and the band returned, disagree with the height it had
    /// just animated to - so every collapse would land 10pt short and grow.
    static func collapsedChromeHeight(barsHeight: CGFloat) -> CGFloat {
        chromeHeight(barsHeight: barsHeight, detent: .collapsed)
    }
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
    /// The host's estimate of the tallest the sheet can get, which seeds the
    /// height the transcript is held at before the sheet has ever been dragged
    /// open. Only a seed: `heldTranscriptHeight` takes over from measurement.
    var transcriptHeight: CGFloat
    /// Fired with the measured height of the chrome's bars, padding excluded.
    /// The host derives the chrome's frame height and the sheet's resting height
    /// from it - see `ConversationSheetMetrics`. The bars rather than the frame,
    /// because the frame's top padding depends on the detent and the resting
    /// height must not.
    var onChromeBarsHeightChanged: (CGFloat) -> Void = { _ in }
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

    /// How much of the sheet is on screen right now, and the most it has ever
    /// been. See `transcript` for why both are measured here rather than handed
    /// in.
    @State private var visibleHeight: CGFloat = 0
    @State private var largestVisibleHeight: CGFloat = 0

    /// Siblings in a ZStack rather than a `safeAreaInset` or a `VStack`, and
    /// the distinction is what makes messages pass under the chrome:
    ///
    /// - A `VStack` gives the chrome its own row, so the transcript stops dead
    ///   at the composer's top edge.
    /// - `safeAreaInset` reserves layout space too - it shrinks the transcript
    ///   the same way - and its inset does not reach the hosted collection
    ///   view's `safeAreaInsets`, so it buys nothing in exchange.
    /// - As ZStack siblings the transcript draws beneath the chrome (it ignores
    ///   the safe area internally), while the chrome respects it and stays clear
    ///   of the home indicator.
    ///
    /// The transcript's own bottom content inset is what keeps its newest
    /// message clear of the chrome; the host supplies it from
    /// `onChromeBarsHeightChanged`.
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
        // TEMPORARY: red outlines the content the sheet handed us.
        .debugBorder(.red)
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

    /// The selected transcript, one constant height at every detent, overflowing
    /// the sheet and clipped to it.
    ///
    /// The constant height is the point. A transcript that filled the detent
    /// would be resized by every drag, and a scroll view anchors its content to
    /// the top through a frame change - so the messages the reader is following
    /// would slide with the sheet unless something shifted the offset back by
    /// the height delta on every layout pass. That compensation is what this
    /// replaces: it ran a frame late, so the wrong position was drawn and then
    /// corrected, and it was not idempotent under UIKit's offset clamping - once
    /// a clamp ate part of a shift, the next pass measured its delta from the
    /// clamped height and the lost scroll position never came back.
    ///
    /// Holding the height fixed means a detent change moves nothing inside the
    /// scroll view. The sheet's edge travels, revealing or hiding content that
    /// was already laid out where it sits now, and the bottom the reader is
    /// following stays exactly where it is - as does any other scroll position,
    /// without arithmetic.
    ///
    /// The transcript stays visible even at `collapsed`, where the sheet is only
    /// as tall as the chrome: the chrome's blurred, fading backdrop covers it
    /// there. Hit-testing follows the detent regardless, so a message under the
    /// grabber cannot steal its drag.
    private var transcript: some View {
        // An overlay on a sheet-sized spacer, rather than a sized view in the
        // stack. An overlay never contributes to its parent's size, and that is
        // what keeps the oversize out of the layout: as a child of the stack, the
        // transcript's fixed height would become the sheet content's *ideal*
        // height, and every pass where the sheet proposes no height of its own
        // would lay the whole thing out at that ideal - pushing the chrome off
        // the bottom of the screen.
        //
        // The spacer doubles as the measurement of how much of the sheet is on
        // screen. Both numbers the overflow is made of are then this view's own,
        // in one coordinate space: a visible height measured somewhere else and
        // subtracted from a height decided here is not the clipped amount, it is
        // the difference between two parties' idea of where the bottom is.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                visibleHeight = height
                largestVisibleHeight = max(largestVisibleHeight, height)
            }
            .overlay(alignment: .bottom) {
                // Taller than the sheet at every detent but `full`, where they
                // meet. Overflows upward, past the sheet's top edge.
                transcriptContent()
                    .environment(\.transcriptClippedTopOverflow, clippedTopOverflow)
                    .frame(height: heldTranscriptHeight, alignment: .bottom)
            }
            // Cuts the overflow at the sheet's bounds, so it is not drawn over
            // the conversation behind the sheet.
            .clipped()
            .allowsHitTesting(detent.showsTranscript)
            // TEMPORARY: blue outlines the transcript's frame.
            .debugBorder(.blue)
    }

    /// Bar and tab bar - the part of the sheet present at every detent. Its
    /// measured height is what the `collapsed` detent resolves to.
    ///
    /// Ignores the bottom safe area, resting near the physical screen edge the
    /// way the native floating tab bar does, rather than sitting above the home
    /// indicator with a band of sheet beneath it.
    private var chrome: some View {
        VStack(spacing: ConversationSheetMetrics.chromeContentSpacing) {
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
        // Measured before the padding is applied, so what the host receives is
        // the part of the chrome that does not vary with the detent.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onChromeBarsHeightChanged(height)
        }
        .padding(.top, ConversationSheetMetrics.chromeTopPadding(for: detent))
        .padding(.bottom, ConversationSheetMetrics.chromeBottomPadding)
        .background { chromeBackdrop }
        // TEMPORARY: green outlines the chrome, paddings included - the height
        // reported as `chromeHeight`.
        .debugBorder(.green)
    }
}

private extension ConversationSheetContent {
    /// The height the transcript is actually held at: never less than the most
    /// of the sheet that has ever been on screen, so it cannot end up shorter
    /// than the detent it is showing through and leave a band of bare sheet
    /// above it. Monotonic, so growing to the full detent once is the only
    /// resize the transcript ever sees.
    var heldTranscriptHeight: CGFloat {
        max(transcriptHeight, largestVisibleHeight)
    }

    /// How much of `heldTranscriptHeight` the sheet is clipping off the top,
    /// which the transcript takes as a top content inset. See
    /// `MessagesViewController.clippedTopOverflow`.
    var clippedTopOverflow: CGFloat {
        max(heldTranscriptHeight - visibleHeight, 0)
    }

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
