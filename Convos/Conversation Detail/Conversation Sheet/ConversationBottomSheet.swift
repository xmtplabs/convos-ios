import BezelKit
import ConvosComposer
import SwiftUI

/// Resting sizes for the floating conversation sheet. Only `.compact` is
/// reachable today; `.half` and `.full` are declared so the detent model,
/// the grabber, and the height plumbing don't need to change shape when the
/// expanded states land.
enum ConversationSheetDetent: CaseIterable {
    /// The floating card: grabber, the selected tab's bar, and the tab bar.
    /// The backing view fills the screen behind it.
    case compact
    /// Roughly half the screen. Not yet reachable.
    case half
    /// The sheet fills the screen up to just below the top bar. Not yet
    /// reachable.
    case full
}

/// Sheet metrics shared with the backing views (e.g. `HomeLayoutView`),
/// which reserve bottom clearance against the compact resting height until
/// the live measurement lands.
enum ConversationSheetMetrics {
    /// Horizontal and bottom inset of the floating compact card, measured
    /// from the physical screen edges: like the native floating tab bar,
    /// the card ignores the bottom safe area and rests under the home
    /// indicator.
    static let edgeInset: CGFloat = 8.0
    /// Continuous corner radii of the compact card: the bottom corners sit
    /// concentric with the device bezel at the 8pt inset (the mock's 48
    /// assumes a 56pt bezel; devices vary, so the radius is derived), and
    /// the top corners stay 8pt tighter, preserving the mock's 40/48
    /// relationship.
    @MainActor
    static var bottomCornerRadius: CGFloat {
        let bezelRadius: CGFloat = CGFloat.deviceBezel > 0 ? .deviceBezel : Fallback.bezelRadius
        return max(bezelRadius - edgeInset, Fallback.minimumBottomRadius)
    }

    @MainActor
    static var topCornerRadius: CGFloat {
        bottomCornerRadius - edgeInset
    }

    private enum Fallback {
        /// The bezel radius the mock's 48pt bottom corner assumes; used when
        /// BezelKit has no entry for the device (e.g. brand-new hardware).
        static let bezelRadius: CGFloat = 56.0
        static let minimumBottomRadius: CGFloat = 24.0
    }
    /// Rough intrinsic height of the compact card (grabber + composer +
    /// tab bar). Only a first-frame estimate: the sheet self-sizes to its
    /// content and reports the measured height to the host.
    static let estimatedCompactHeight: CGFloat = 172.0
    /// Vertical clearance the resting compact card occupies above the
    /// physical bottom screen edge, inset included. First-frame estimate;
    /// the live value arrives via `onOccupiedHeightChanged`.
    static var compactRestingHeight: CGFloat { estimatedCompactHeight + edgeInset }
}

/// The floating conversation sheet: a bottom-pinned card holding a grabber,
/// the selected tab's bar (composer or nothing), and the conversation tab
/// bar. Deliberately not a `.sheet`: the conversation screen presents many
/// sheets from its root (a persistent detent sheet would occupy the
/// presentation slot), and the backing view behind must stay fully
/// interactive.
///
/// The card self-sizes to its content - the hosted composer grows for
/// attachment previews, reply bars, and the quick editor - and rides the
/// keyboard through the normal safe-area behavior of its host. Its measured
/// clearance (card height plus the bottom edge inset, keyboard excluded) is
/// reported through `onOccupiedHeightChanged` so backing views can inset
/// their content above the resting card.
///
/// The grabber carries the detent drag. With only `.compact` reachable the
/// drag rubber-bands and springs back, but the gesture, detent binding, and
/// snap plumbing are already in place for `.half`/`.full`.
struct ConversationBottomSheet<BarContent: View, TabBarContent: View>: View {
    @Binding var detent: ConversationSheetDetent
    /// Detents the grabber may snap to. Compact-only today.
    var supportedDetents: [ConversationSheetDetent] = [.compact]
    /// Fades the whole card out (and disables interaction) while transient
    /// chrome owns the screen, e.g. the message long-press context menu.
    var isHidden: Bool = false
    /// Whether the grabber renders. Off while `.compact` is the only detent
    /// - a drag affordance that can't resize anything is a lie; flip it back
    /// on when `.half`/`.full` become reachable.
    var showsGrabber: Bool = false
    /// Fired with the card's live bottom clearance: measured card height plus
    /// the bottom edge inset. Keyboard displacement is excluded - hosts feed
    /// this to transcript insets whose controllers track the keyboard
    /// themselves.
    var onOccupiedHeightChanged: (CGFloat) -> Void = { _ in }
    /// The selected tab's bar, e.g. the group or agent composer. May resolve
    /// to nothing (the Home tab hides its bar).
    @ViewBuilder let barContent: () -> BarContent
    @ViewBuilder let tabBar: () -> TabBarContent

    @State private var dragOffset: CGFloat = 0
    /// The card's live height, used to clamp the top corner radius: on the
    /// compact Home tab (no composer) the ideal top+bottom radii exceed
    /// the card height and SwiftUI would compress BOTH corners, pulling the
    /// bottom out of bezel concentricity. The bottom radius never yields;
    /// the top shrinks instead.
    @State private var cardHeight: CGFloat = ConversationSheetMetrics.estimatedCompactHeight

    var body: some View {
        VStack(spacing: Constant.contentSpacing) {
            barContent()
            tabBar()
        }
        .padding(.top, Constant.contentTopPadding)
        .padding(.bottom, Constant.contentBottomPadding)
        .frame(maxWidth: .infinity)
        .background {
            cardShape
                .fill(Color.colorBackgroundRaised)
                .shadow(color: Constant.shadowColor, radius: Constant.shadowRadius, y: Constant.shadowYOffset)
        }
        // The grabber floats near the card's top edge, over the content's
        // top padding (Figma pins it 6pt in).
        .overlay(alignment: .top) {
            if showsGrabber {
                grabber
            }
        }
        .padding(.horizontal, ConversationSheetMetrics.edgeInset)
        .padding(.bottom, ConversationSheetMetrics.edgeInset)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            // The measured frame already includes the bottom edge-inset
            // padding, so the height is the card's full bottom clearance.
            cardHeight = height - ConversationSheetMetrics.edgeInset
            onOccupiedHeightChanged(height)
        }
        .offset(y: max(dragOffset, 0) * Constant.downwardRubberBandFactor - rubberBandedLift)
        .opacity(isHidden ? 0.0 : 1.0)
        .allowsHitTesting(!isHidden)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: isHidden)
        .accessibilityIdentifier("conversation-bottom-sheet")
    }

    /// Upward drag resistance while `.half`/`.full` are unreachable: the card
    /// lifts a fraction of the drag and eases off, signaling "more sheet"
    /// without committing to a detent change.
    private var rubberBandedLift: CGFloat {
        let upwardDrag: CGFloat = max(-dragOffset, 0)
        guard upwardDrag > 0 else { return 0 }
        return Constant.maxRubberBandLift * (1 - exp(-upwardDrag / Constant.rubberBandDistance))
    }

    private var cardShape: UnevenRoundedRectangle {
        let bottomRadius: CGFloat = ConversationSheetMetrics.bottomCornerRadius
        // When the ideal radii don't fit the card's height, only the top
        // yields - the bottom stays concentric with the bezel.
        let topRadius: CGFloat = min(
            ConversationSheetMetrics.topCornerRadius,
            max(cardHeight - bottomRadius, Constant.minimumTopCornerRadius)
        )
        return UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: topRadius,
                bottomLeading: bottomRadius,
                bottomTrailing: bottomRadius,
                topTrailing: topRadius
            ),
            style: .continuous
        )
    }

    private var grabber: some View {
        Capsule()
            .fill(.colorFillTertiary)
            .frame(width: Constant.grabberWidth, height: Constant.grabberHeight)
            .padding(.top, Constant.grabberTopPadding)
            .frame(maxWidth: .infinity)
            .frame(height: Constant.grabberHitAreaHeight, alignment: .top)
            .contentShape(.rect)
            .gesture(grabberDrag)
            .accessibilityIdentifier("conversation-sheet-grabber")
    }

    private var grabberDrag: some Gesture {
        // Measured in a stable coordinate space: the grabber rides the card's
        // top edge, so a local-space translation would feed back into itself
        // as the card moves under the finger.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                dragOffset = value.translation.height
            }
            .onEnded { _ in
                // Compact is the only supported detent, so every release
                // springs home. When `.half`/`.full` become reachable this is
                // where the released offset + velocity resolve to a snapped
                // detent (see ConversationSheetDetent).
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    dragOffset = 0
                    detent = .compact
                }
            }
    }
}

// Hoisted out of the generic sheet type: generic types cannot hold static
// stored properties.
private enum Constant {
    /// Grabber metrics from Figma 7156:13838: 56x4, pinned 6pt from the
    /// card's top edge, with a taller invisible hit area for the drag.
    static let grabberWidth: CGFloat = 56.0
    static let grabberHeight: CGFloat = 4.0
    static let grabberTopPadding: CGFloat = 6.0
    static let grabberHitAreaHeight: CGFloat = 28.0
    /// Card content: 16pt padding with a 12pt gap between the bar and the
    /// tab bar (Figma p-16 / gap-12). Horizontal insets stay with the bar
    /// content itself - the composer already carries the 16pt inset.
    static let contentSpacing: CGFloat = DesignConstants.Spacing.step3x
    static let contentTopPadding: CGFloat = DesignConstants.Spacing.step4x
    static let contentBottomPadding: CGFloat = DesignConstants.Spacing.step4x
    /// Floor for the clamped top corner radius on very short cards.
    static let minimumTopCornerRadius: CGFloat = 16.0
    /// The design's "Cheap glass" drop shadow: 8% black, radius 16, y 4.
    static let shadowColor: Color = Color.black.opacity(0.08)
    static let shadowRadius: CGFloat = 16.0
    static let shadowYOffset: CGFloat = 4.0
    /// A downward drag moves the card at reduced rate and springs back.
    static let downwardRubberBandFactor: CGFloat = 0.35
    /// Asymptotic ceiling of the upward rubber-band lift.
    static let maxRubberBandLift: CGFloat = 32.0
    /// Drag distance over which the upward lift approaches its ceiling.
    static let rubberBandDistance: CGFloat = 160.0
}
