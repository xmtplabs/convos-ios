import SwiftUI

/// Bar that lets the user kick off an agent-builder draft. Renders one
/// stable glass capsule whose width + tint animate between two states:
///
/// - **Expanded**: a capsule -- agent avatar leading, a "Make an agent"
///   placeholder label, and a trailing icon button for the voice-memo entry
///   point. Capped at the width it would occupy on the largest iPhone in
///   portrait so it doesn't stretch the full width of a wide iPad, and
///   centered within the available width.
/// - **Collapsed**: a 52pt circle at the trailing edge (the capsule shrunk
///   to its height with a black tint so it reads as a solid agent avatar).
///
/// The expanded capsule is centered while the collapsed circle pins to the
/// trailing edge, so the morph slides the shape from center to trailing as
/// it shrinks.
///
/// `MainTabView` drives `isExpanded` from scroll position. On iPhone the bar
/// pins to the top and fades out entirely on scroll (a compact "add agent"
/// button takes its place in the nav bar), so it stays `isExpanded: true`
/// and the parent animates opacity. On iPad the bar pins to the bottom and
/// collapses to the circle on scroll via `isExpanded`.
///
/// Keeping it one stable view (cross-fading the two inner layouts) means a
/// parent-applied `.matchedTransitionSource(_:in:)` stays anchored to the
/// glass surface across the morph, so sheets presented from the bar zoom out
/// of whichever shape is currently visible.
struct AgentBuilderBar: View {
    let isExpanded: Bool
    let onTap: () -> Void
    let onTapVoiceMemo: () -> Void
    /// Optional matched-transition source applied to the glass shape. When
    /// set, sheets presented after tapping the bar zoom out of it.
    var transitionSourceNamespace: Namespace.ID?
    var transitionSourceId: String?

    var body: some View {
        HStack(spacing: 0) {
            // The expanded capsule is centered (a spacer on each side); the
            // collapsed circle keeps only the leading spacer so it pins to
            // the trailing edge. The morph slides the shape from center to
            // trailing as it shrinks. On a phone the capsule fills the
            // available width (the cap doesn't bind), so the spacers
            // collapse to zero.
            Spacer(minLength: 0)
            glassShape
            if isExpanded {
                Spacer(minLength: 0)
            }
        }
        .animation(.smooth(duration: 0.25), value: isExpanded)
    }

    private var glassShape: some View {
        ZStack {
            expandedContent
                .opacity(isExpanded ? 1 : 0)
                .allowsHitTesting(isExpanded)
            collapsedContent
                .opacity(isExpanded ? 0 : 1)
                .allowsHitTesting(!isExpanded)
        }
        .frame(
            maxWidth: isExpanded ? Constant.maxExpandedWidth : Constant.collapsedSize,
            minHeight: Constant.barHeight
        )
        .contentShape(.capsule)
        .onTapGesture(perform: onTap)
        .glassEffect(currentGlass, in: .capsule)
        .modifier(MatchedTransitionSourceModifier(
            namespace: transitionSourceNamespace,
            id: transitionSourceId
        ))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isExpanded ? "agent-builder-bar-expanded" : "agent-builder-bar-collapsed")
    }

    private var currentGlass: Glass {
        isExpanded
            ? .regular.interactive()
            : .regular.tint(Color.black).interactive()
    }

    private var expandedContent: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            agentAvatar

            Text("Make an agent")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            voiceMemoButton
        }
        .padding(DesignConstants.Spacing.step2x)
        .frame(maxWidth: .infinity)
    }

    private var collapsedContent: some View {
        Image("addAgentIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .frame(width: Constant.collapsedIconSize, height: Constant.collapsedIconSize)
            .frame(width: Constant.collapsedSize, height: Constant.collapsedSize)
    }

    private var voiceMemoButton: some View {
        Button(action: onTapVoiceMemo) {
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.colorTextSecondary)
                .frame(width: Constant.trailingIconWidth, height: Constant.trailingIconHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel("Record voice memo")
        .padding(.horizontal, Constant.trailingIconHorizontalPadding)
    }

    private var agentAvatar: some View {
        // Expanded state: the bare glyph on the glass bar (no enclosing
        // circle). The collapsed state still reads as a solid agent avatar --
        // its circle is the black-tinted glass shrunk to its height.
        Image("addAgentIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color.colorTextPrimary)
            .padding(Constant.expandedIconInsets)
            .frame(width: Constant.expandedIconFrameSize, height: Constant.expandedIconFrameSize)
            .accessibilityLabel("Make an agent")
    }

    private enum Constant {
        /// Height of both visual states: the expanded content's natural height
        /// (36pt glyph footprint + step2x*2 padding = 52pt). The collapsed
        /// circle matches it, so the morph keeps a constant vertical footprint.
        static let barHeight: CGFloat = 52.0
        static let collapsedSize: CGFloat = 52.0
        static let collapsedIconSize: CGFloat = 24.0
        /// Widest the expanded capsule grows. Matches the width it would have
        /// on the largest iPhone in portrait (440pt screen less the bar's
        /// step4x side margins on each edge), so on a wide iPad it stays a
        /// trailing capsule rather than stretching edge to edge. On a phone
        /// the available width is always <= this, so the cap never binds.
        static let maxExpandedWidth: CGFloat = 408.0
        /// The leading glyph sits in a 36x36 footprint, inset per the design so
        /// the visible mark (~16.7x18) reads in line with the trailing icon.
        /// The asset has no internal padding, so the inset is applied here.
        static let expandedIconFrameSize: CGFloat = 36.0
        static let expandedIconInsets: EdgeInsets = EdgeInsets(top: 8, leading: 10.67, bottom: 10, trailing: 8.67)
        static let trailingIconWidth: CGFloat = 20.0
        static let trailingIconHeight: CGFloat = 18.0
        static let trailingIconHorizontalPadding: CGFloat = 8.0
    }
}

/// Conditional matched-transition source modifier: applies the modifier
/// when both `namespace` and `id` are non-nil, otherwise no-op.
private struct MatchedTransitionSourceModifier: ViewModifier {
    let namespace: Namespace.ID?
    let id: String?

    func body(content: Content) -> some View {
        if let namespace, let id {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

#Preview("Expanded") {
    AgentBuilderBar(isExpanded: true, onTap: {}, onTapVoiceMemo: {})
        .padding()
        .background(Color.colorBackgroundSurfaceless)
}

#Preview("Collapsed") {
    AgentBuilderBar(isExpanded: false, onTap: {}, onTapVoiceMemo: {})
        .padding()
        .background(Color.colorBackgroundSurfaceless)
}
