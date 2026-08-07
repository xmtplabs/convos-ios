import SwiftUI
import BezelKit

private struct DesktopTranscriptOpacityKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

private struct IsDesktopDrawerResizingKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// Transcript-only visibility supplied by the desktop drawer. Other
    /// conversation layouts inherit the fully-visible default.
    var desktopTranscriptOpacity: Double {
        get { self[DesktopTranscriptOpacityKey.self] }
        set { self[DesktopTranscriptOpacityKey.self] = newValue }
    }

    /// Lets the UIKit transcript distinguish an active desktop drawer resize
    /// from ordinary conversation size transitions.
    var isDesktopDrawerResizing: Bool {
        get { self[IsDesktopDrawerResizingKey.self] }
        set { self[IsDesktopDrawerResizingKey.self] = newValue }
    }
}

/// Resting heights for the desktop-mode chat drawer.
enum ConversationDrawerDetent: CaseIterable {
    /// The compose card: composer, switcher, and grabber only; the chat is
    /// concealed entirely and the desktop fills the screen.
    case collapsed
    /// Roughly half the screen: the last few messages above the composer.
    case partial
    /// Chat fills the screen up to just below the top bar.
    case full
}

/// Drawer metrics shared with `DesktopLayoutView`, which sizes its web
/// section and bottom scroll margin against the collapsed resting height so
/// the desktop content clears the resting compose card.
enum ConversationDrawerMetrics {
    /// Roughly the input capsule + switcher + grabber; a measured height
    /// can replace this later.
    static let collapsedHeight: CGFloat = 148.0
    /// Horizontal and bottom inset of the collapsed floating compose card.
    /// The drawer sheds it while expanding, landing full width and flush
    /// with the bottom of the screen.
    static let collapsedEdgeInset: CGFloat = 8.0
    /// Insetting a shape by `collapsedEdgeInset` reduces its radius by the
    /// same amount, keeping the collapsed card concentric with the bezel.
    @MainActor
    static var deviceBezelCornerRadius: CGFloat { .deviceBezel }
    @MainActor
    static var collapsedCornerRadius: CGFloat {
        max(deviceBezelCornerRadius - collapsedEdgeInset / 2.0, 0)
    }
    /// Vertical space the resting collapsed card occupies from the bottom
    /// edge, inset included.
    static var collapsedRestingHeight: CGFloat { collapsedHeight + collapsedEdgeInset }
}

/// Custom bottom drawer hosting the chat in desktop mode. Deliberately not a
/// `.sheet`: the conversation screen presents many sheets from its root (a
/// persistent detent sheet would occupy the presentation slot), and the
/// desktop behind must stay fully interactive.
///
/// Collapsed, the drawer rests as a floating compose card: inset from the
/// screen edges and rounded on every corner, with the chat hidden inside it.
/// Expanding morphs it into a full-width sheet flush with the bottom of the
/// screen, revealing the chat through the `partial` and `full` detents.
/// Scaffold mechanics: the drag gesture lives on the grabber only, so it
/// never fights the transcript's vertical scroll or the pager's horizontal
/// swipe.
struct ConversationDrawer<Content: View>: View {
    @Binding var detent: ConversationDrawerDetent
    /// Extra height added to the `.collapsed` resting position, letting the
    /// host reserve room above the composer (e.g. for transient chrome).
    /// Changes animate while the drawer rests at `.collapsed`.
    var extraCollapsedHeight: CGFloat = 0
    /// The keyboard pins the drawer at full height; while it is present the
    /// grabber remains visible but does not accept a conflicting drag.
    var allowsDragging: Bool = true
    /// Supplies live card-to-sheet expansion directly to the content without
    /// writing it back through the parent on every drag sample.
    @ViewBuilder let content: (CGFloat) -> Content

    @State private var dragOffset: CGFloat = 0
    @State private var isResizing: Bool = false

    var body: some View {
        // Ignoring the container's bottom inset lets the expanded sheet sit
        // flush with the bottom of the screen instead of the safe area. The
        // hosted content keeps its safe-area-bound frame (padded back below),
        // so only the drawer surface extends under the home indicator.
        GeometryReader { proxy in
            let bottomInset: CGFloat = proxy.safeAreaInsets.bottom
            let availableHeight: CGFloat = proxy.size.height - bottomInset
            let restingHeight: CGFloat = height(for: detent, in: availableHeight)
            let minHeight: CGFloat = collapsedHeight
            let maxHeight: CGFloat = height(for: .full, in: availableHeight)
            let currentHeight: CGFloat = min(max(restingHeight - dragOffset, minHeight), maxHeight)
            drawerBody(height: currentHeight, availableHeight: availableHeight, bottomInset: bottomInset)
                .padding(.bottom, bottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private func drawerBody(height: CGFloat, availableHeight: CGFloat, bottomInset: CGFloat) -> some View {
        // 0 while resting as the collapsed card, 1 once the drawer reaches
        // the partial detent; drives the card-to-sheet morph while dragging.
        let expansion: CGFloat = expansionProgress(for: height, in: availableHeight)
        let cardness: CGFloat = 1 - expansion
        let bottomRadius: CGFloat = Constant.cardCornerRadius * cardness
        let edgeInset: CGFloat = ConversationDrawerMetrics.collapsedEdgeInset * cardness
        // As the card morphs into the sheet, the surface sheds the card inset
        // and grows past the safe area until it is flush with the screen edge.
        let surfaceBottomPadding: CGFloat = edgeInset - bottomInset * expansion
        let shape = UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: Constant.cardCornerRadius,
            bottomLeading: bottomRadius,
            bottomTrailing: bottomRadius,
            topTrailing: Constant.cardCornerRadius
        ))
        return content(expansion)
            .environment(\.isDesktopDrawerResizing, isResizing)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            // Keep the hosted conversation at a stable width throughout the
            // drag. Padding the entire subtree continuously resized the UIKit
            // transcript and churned its trait environment; masking produces
            // the same card-to-sheet morph without relaying out the chat.
            .mask {
                shape
                    .padding(.horizontal, edgeInset)
                    .padding(.bottom, edgeInset)
            }
            // The surface is drawn behind the masked content so it can extend
            // below the content frame; the mask would clip an in-frame fill.
            .background {
                shape
                    .fill(Color.colorBackgroundSurfaceless)
                    .padding(.horizontal, edgeInset)
                    .padding(.bottom, surfaceBottomPadding)
            }
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
            .gesture(
                dragGesture(availableHeight: availableHeight),
                including: allowsDragging ? .all : .none
            )
            .accessibilityIdentifier("conversation-drawer-grabber")
    }

    private func dragGesture(availableHeight: CGFloat) -> some Gesture {
        // The gesture must be measured in a stable coordinate space: the
        // grabber rides the drawer's top edge, so a local-space translation
        // feeds back into itself as the drawer resizes under the finger
        // (visible as high-frequency height jitter during the drag).
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                isResizing = true
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let restingHeight: CGFloat = height(for: detent, in: availableHeight)
                let currentHeight: CGFloat = clampedHeight(
                    restingHeight - value.translation.height,
                    in: availableHeight
                )
                let snapped: ConversationDrawerDetent = targetDetent(
                    forReleasedHeight: currentHeight,
                    verticalVelocity: value.velocity.height,
                    in: availableHeight
                )
                let snappedHeight: CGFloat = height(for: snapped, in: availableHeight)

                // Preserve the exact visible height while swapping the
                // discrete base detent, then spring only the remaining offset.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    detent = snapped
                    dragOffset = snappedHeight - currentHeight
                }
                withAnimation(
                    .spring(response: 0.35, dampingFraction: 0.85),
                    completionCriteria: .removed
                ) {
                    dragOffset = 0
                } completion: {
                    isResizing = false
                }
            }
    }

    private var collapsedHeight: CGFloat {
        ConversationDrawerMetrics.collapsedHeight + extraCollapsedHeight
    }

    private func height(for detent: ConversationDrawerDetent, in availableHeight: CGFloat) -> CGFloat {
        switch detent {
        case .collapsed:
            return collapsedHeight
        case .partial:
            return availableHeight * Constant.partialFraction
        case .full:
            return max(availableHeight - Constant.topClearance, collapsedHeight)
        }
    }

    /// Progress of the card-to-sheet morph: 0 at the collapsed resting
    /// height, 1 at the partial detent and beyond.
    private func expansionProgress(for currentHeight: CGFloat, in availableHeight: CGFloat) -> CGFloat {
        let partialHeight: CGFloat = height(for: .partial, in: availableHeight)
        let range: CGFloat = partialHeight - collapsedHeight
        guard range > 0 else { return 1 }
        let raw: CGFloat = (currentHeight - collapsedHeight) / range
        return min(max(raw, 0), 1)
    }

    private func clampedHeight(_ proposedHeight: CGFloat, in availableHeight: CGFloat) -> CGFloat {
        min(max(proposedHeight, collapsedHeight), height(for: .full, in: availableHeight))
    }

    /// A flick past the velocity threshold commits one detent in the flick's
    /// direction no matter where the finger stopped, so a short sharp drag
    /// still opens or closes the drawer. Slower releases settle on whichever
    /// detent is nearest the released height.
    private func targetDetent(
        forReleasedHeight releasedHeight: CGFloat,
        verticalVelocity: CGFloat,
        in availableHeight: CGFloat
    ) -> ConversationDrawerDetent {
        if verticalVelocity <= -Constant.velocityThreshold {
            return detentAbove(releasedHeight, in: availableHeight)
        }
        if verticalVelocity >= Constant.velocityThreshold {
            return detentBelow(releasedHeight, in: availableHeight)
        }
        return nearestDetent(to: releasedHeight, in: availableHeight)
    }

    private func sortedDetents(in availableHeight: CGFloat) -> [ConversationDrawerDetent] {
        ConversationDrawerDetent.allCases.sorted { lhs, rhs in
            height(for: lhs, in: availableHeight) < height(for: rhs, in: availableHeight)
        }
    }

    private func detentAbove(_ releasedHeight: CGFloat, in availableHeight: CGFloat) -> ConversationDrawerDetent {
        let above: ConversationDrawerDetent? = sortedDetents(in: availableHeight).first { candidate in
            height(for: candidate, in: availableHeight) > releasedHeight + Constant.detentSlack
        }
        return above ?? .full
    }

    private func detentBelow(_ releasedHeight: CGFloat, in availableHeight: CGFloat) -> ConversationDrawerDetent {
        let below: ConversationDrawerDetent? = sortedDetents(in: availableHeight).last { candidate in
            height(for: candidate, in: availableHeight) < releasedHeight - Constant.detentSlack
        }
        return below ?? .collapsed
    }

    private func nearestDetent(to target: CGFloat, in availableHeight: CGFloat) -> ConversationDrawerDetent {
        var nearest: ConversationDrawerDetent = detent
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
    static let topClearance: CGFloat = 16.0
    @MainActor
    static let cardCornerRadius: CGFloat = ConversationDrawerMetrics.collapsedCornerRadius
    static let grabberWidth: CGFloat = 36.0
    static let grabberHeight: CGFloat = 5.0
    static let grabberHitAreaHeight: CGFloat = 28.0
    /// Vertical flick speed (points per second) past which the release
    /// commits one detent in the flick's direction.
    static let velocityThreshold: CGFloat = 250.0
    /// Keeps a directional flick from re-selecting the detent the drawer is
    /// already effectively resting at.
    static let detentSlack: CGFloat = 1.0
}
