#if canImport(UIKit)
import SwiftUI

/// Reusable "thought bubble" container. A rounded rect (20pt corner
/// radius, 16h × 8v content padding) with two trailing circles at the
/// bottom-leading edge that evoke a thought bubble's tail. Used for
/// thinking-related cells in `ThinkingDetailView` so the bubbles read as
/// the agent's internal monologue rather than regular chat messages.
///
/// Layout:
/// - The bigger circle straddles the container's bottom-leading corner —
///   its center sits exactly on that corner — so its bottom aligns with
///   the container's bottom edge (and with the avatar's bottom on
///   single-line runs).
/// - The smaller circle sits further below-left of the big circle, fully
///   outside the container's frame. Both circles are `.overlay` with
///   `.offset`, so parent layouts don't reserve extra space for them —
///   they render past the container's bounds as decorative chrome.
struct ThoughtBubble<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var color: Color = .colorBackgroundRaised
    /// Mirrors the tail to the bottom-trailing corner for messages sent by
    /// the current user (brainstorm view). Incoming/default keeps the
    /// bottom-leading tail.
    var isOutgoing: Bool = false

    private let cornerRadius: CGFloat = 20.0
    private let bigCircleSize: CGFloat = 12.0
    private let smallCircleSize: CGFloat = 6.0
    private let horizontalPadding: CGFloat = 16.0
    private let verticalPadding: CGFloat = 8.0
    /// How many points the small circle's top-right bounding-box corner
    /// overlaps the big circle's bottom-left bounding-box corner. 1pt is
    /// enough that the two read as a connected "tail" — the inscribed
    /// circles themselves don't quite touch, but the diagonal continuity
    /// of the chrome reads as one shape.
    private let smallCircleCornerOverlap: CGFloat = 1.0

    var body: some View {
        let tailAlignment: Alignment = isOutgoing ? .bottomTrailing : .bottomLeading
        let smallCircleXOffset: CGFloat = isOutgoing
            ? smallCircleSize - smallCircleCornerOverlap
            : -smallCircleSize + smallCircleCornerOverlap
        content()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(color)
            )
            // Big circle: bbox bottom corner sits exactly on the rect's
            // bottom bbox corner on the tail side. With the tail-side
            // alignment and no offset, the circle's 12×12 bbox occupies
            // that corner area. The rect's 20pt rounded corner curves
            // inward from there, so the circle's outer portion bleeds out
            // past the curve as the tail.
            .overlay(alignment: tailAlignment) {
                Circle()
                    .fill(color)
                    .frame(width: bigCircleSize, height: bigCircleSize)
            }
            // Small circle: bbox inner-top corner overlaps the big circle's
            // bbox outer-bottom corner by `smallCircleCornerOverlap` pt,
            // diagonally, mirrored to the tail side.
            .overlay(alignment: tailAlignment) {
                Circle()
                    .fill(color)
                    .frame(width: smallCircleSize, height: smallCircleSize)
                    .offset(
                        x: smallCircleXOffset,
                        y: smallCircleSize - smallCircleCornerOverlap
                    )
            }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        ThoughtBubble {
            Text("Single line")
                .font(.callout)
        }
        ThoughtBubble {
            Text("Multi-line content\nspans two rows\nor more")
                .font(.callout)
        }
        ThoughtBubble {
            PulsingCircleView.thinkingIndicator
                .frame(height: UIFont.preferredFont(forTextStyle: .callout).lineHeight)
        }
    }
    .padding(40)
    .background(.colorBackgroundSurfaceless)
}
#endif
