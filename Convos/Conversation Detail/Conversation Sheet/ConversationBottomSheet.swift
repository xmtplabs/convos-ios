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

/// Sheet metrics shared with the backing views (e.g. `DesktopLayoutView`),
/// which reserve bottom clearance against the compact resting height until
/// the live measurement lands.
enum ConversationSheetMetrics {
    /// Horizontal and bottom inset of the floating compact card.
    static let edgeInset: CGFloat = 8.0
    /// Continuous corner radius of the compact card, sized to sit close to
    /// concentric with the device bezel at the 8pt inset.
    static let cornerRadius: CGFloat = 34.0
    /// Rough intrinsic height of the compact card (grabber + composer +
    /// tab bar). Only a first-frame estimate: the sheet self-sizes to its
    /// content and reports the measured height to the host.
    static let estimatedCompactHeight: CGFloat = 172.0
    /// Vertical clearance the resting compact card occupies above the bottom
    /// safe-area edge, inset included. First-frame estimate; the live value
    /// arrives via `onOccupiedHeightChanged`.
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
    /// Fired with the card's live bottom clearance: measured card height plus
    /// the bottom edge inset. Keyboard displacement is excluded - hosts feed
    /// this to transcript insets whose controllers track the keyboard
    /// themselves.
    var onOccupiedHeightChanged: (CGFloat) -> Void = { _ in }
    /// The selected tab's bar, e.g. the group or agent composer. May resolve
    /// to nothing (the Desktop tab hides its bar).
    @ViewBuilder let barContent: () -> BarContent
    @ViewBuilder let tabBar: () -> TabBarContent

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            grabber
            barContent()
            tabBar()
                .padding(.top, Constant.tabBarPaddingTop)
                .padding(.bottom, Constant.tabBarPaddingBottom)
        }
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: ConversationSheetMetrics.cornerRadius, style: .continuous)
                .fill(Color.colorBackgroundSurfaceless)
                .shadow(color: Constant.shadowColor, radius: Constant.shadowRadius, y: Constant.shadowYOffset)
        }
        .padding(.horizontal, ConversationSheetMetrics.edgeInset)
        .padding(.bottom, ConversationSheetMetrics.edgeInset)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            // The measured frame already includes the bottom edge-inset
            // padding, so the height is the card's full bottom clearance.
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

    private var grabber: some View {
        Capsule()
            .fill(.colorFillTertiary)
            .frame(width: Constant.grabberWidth, height: Constant.grabberHeight)
            .frame(maxWidth: .infinity)
            .frame(height: Constant.grabberHitAreaHeight)
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
    static let grabberWidth: CGFloat = 44.0
    static let grabberHeight: CGFloat = 5.0
    static let grabberHitAreaHeight: CGFloat = 26.0
    static let tabBarPaddingTop: CGFloat = DesignConstants.Spacing.stepX
    static let tabBarPaddingBottom: CGFloat = DesignConstants.Spacing.step2x
    /// Kept faint: a heavier spread dithers into a visible band over the
    /// light desktop background.
    static let shadowColor: Color = Color.black.opacity(0.06)
    static let shadowRadius: CGFloat = 10.0
    static let shadowYOffset: CGFloat = 2.0
    /// A downward drag moves the card at reduced rate and springs back.
    static let downwardRubberBandFactor: CGFloat = 0.35
    /// Asymptotic ceiling of the upward rubber-band lift.
    static let maxRubberBandLift: CGFloat = 32.0
    /// Drag distance over which the upward lift approaches its ceiling.
    static let rubberBandDistance: CGFloat = 160.0
}
