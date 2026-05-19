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
        content()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(color)
            )
            // Big circle: bbox bottom-left corner sits exactly on the
            // rect's bottom-leading bbox corner. With `.bottomLeading`
            // alignment and no offset, the circle's 12×12 bbox occupies
            // the rect's bottom-leading corner area. The rect's 20pt
            // rounded corner curves inward from there, so the circle's
            // bottom-leading portion bleeds out past the curve as the
            // tail.
            .overlay(alignment: .bottomLeading) {
                Circle()
                    .fill(color)
                    .frame(width: bigCircleSize, height: bigCircleSize)
            }
            // Small circle: bbox top-right overlaps the big circle's bbox
            // bottom-left by `smallCircleCornerOverlap` pt, diagonally.
            .overlay(alignment: .bottomLeading) {
                Circle()
                    .fill(color)
                    .frame(width: smallCircleSize, height: smallCircleSize)
                    .offset(
                        x: -smallCircleSize + smallCircleCornerOverlap,
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
