import SwiftUI

/// Resting heights for the desktop-mode chat drawer.
enum ConversationDrawerDetent: CaseIterable {
    /// Composer, switcher, and grabber only; the desktop fills the screen.
    case collapsed
    /// Roughly half the screen: the last few messages above the composer.
    case partial
    /// Chat fills the screen up to just below the top bar.
    case full
}

/// Drawer metrics shared with `DesktopLayoutView`, which sizes its web
/// section and bottom scroll margin against the collapsed resting height so
/// the desktop content clears the resting drawer.
enum ConversationDrawerMetrics {
    /// Roughly the input capsule + switcher + grabber; a measured height
    /// can replace this later.
    static let collapsedHeight: CGFloat = 148.0
}

/// Custom bottom drawer hosting the chat in desktop mode. Deliberately not a
/// `.sheet`: the conversation screen presents many sheets from its root (a
/// persistent detent sheet would occupy the presentation slot), and the
/// desktop behind must stay fully interactive. Scaffold mechanics: the drag
/// gesture lives on the grabber only, so it never fights the transcript's
/// vertical scroll or the pager's horizontal swipe.
struct ConversationDrawer<Content: View>: View {
    @Binding var detent: ConversationDrawerDetent
    /// Extra height added to the `.collapsed` resting position, letting the
    /// host reserve room above the composer (e.g. for transient chrome).
    /// Changes animate while the drawer rests at `.collapsed`.
    var extraCollapsedHeight: CGFloat = 0
    @ViewBuilder let content: () -> Content

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let availableHeight: CGFloat = proxy.size.height
            let restingHeight: CGFloat = height(for: detent, in: availableHeight)
            let minHeight: CGFloat = ConversationDrawerMetrics.collapsedHeight + extraCollapsedHeight
            let maxHeight: CGFloat = height(for: .full, in: availableHeight)
            let currentHeight: CGFloat = min(max(restingHeight - dragOffset, minHeight), maxHeight)
            drawerBody(height: currentHeight, availableHeight: availableHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func drawerBody(height: CGFloat, availableHeight: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: Constant.cornerRadius,
            bottomLeading: 0,
            bottomTrailing: 0,
            topTrailing: Constant.cornerRadius
        ))
        return content()
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(.colorBackgroundSurfaceless)
            .clipShape(shape)
            .overlay(alignment: .top) {
                grabber(availableHeight: availableHeight)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: detent)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: extraCollapsedHeight)
    }

    private func grabber(availableHeight: CGFloat) -> some View {
        Capsule()
            .fill(.colorFillTertiary)
            .frame(width: Constant.grabberWidth, height: Constant.grabberHeight)
            .frame(maxWidth: .infinity)
            .frame(height: Constant.grabberHitAreaHeight)
            .contentShape(.rect)
            .gesture(dragGesture(availableHeight: availableHeight))
            .accessibilityIdentifier("conversation-drawer-grabber")
    }

    private func dragGesture(availableHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let projectedHeight: CGFloat = height(for: detent, in: availableHeight) - value.predictedEndTranslation.height
                let snapped: ConversationDrawerDetent = nearestDetent(to: projectedHeight, in: availableHeight)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    detent = snapped
                    dragOffset = 0
                }
            }
    }

    private func height(for detent: ConversationDrawerDetent, in availableHeight: CGFloat) -> CGFloat {
        let collapsedHeight: CGFloat = ConversationDrawerMetrics.collapsedHeight + extraCollapsedHeight
        switch detent {
        case .collapsed:
            return collapsedHeight
        case .partial:
            return availableHeight * Constant.partialFraction
        case .full:
            return max(availableHeight - Constant.topClearance, collapsedHeight)
        }
    }

    private func nearestDetent(to target: CGFloat, in availableHeight: CGFloat) -> ConversationDrawerDetent {
        var nearest: ConversationDrawerDetent = .collapsed
        var smallestDistance: CGFloat = .infinity
        for candidate in ConversationDrawerDetent.allCases {
            let distance: CGFloat = abs(height(for: candidate, in: availableHeight) - target)
            if distance < smallestDistance {
                smallestDistance = distance
                nearest = candidate
            }
        }
        return nearest
    }
}

// File scope because static stored properties aren't supported inside the
// generic drawer type.
private enum Constant {
    static let partialFraction: CGFloat = 0.45
    /// Clears the centered conversation title pill drawn above everything.
    static let topClearance: CGFloat = 64.0
    static let cornerRadius: CGFloat = DesignConstants.CornerRadius.mediumLarge
    static let grabberWidth: CGFloat = 36.0
    static let grabberHeight: CGFloat = 5.0
    static let grabberHitAreaHeight: CGFloat = 28.0
}
