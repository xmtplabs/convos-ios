import SwiftUI

/// Bottom-accessory bar above the iOS 26 floating tab bar that lets the
/// user kick off an agent-builder draft. Renders one stable glass
/// capsule whose **width and tint** animate between two visual states:
///
/// - **Expanded**: full-width capsule with the agent avatar leading, a
///   "Make an agent" placeholder label, and three trailing icon buttons
///   for photo / camera / voice memo entry points.
///
/// - **Collapsed**: 56pt circle (visually) at the trailing edge — the
///   same glass capsule shrunk to its height with a black tint so it
///   reads as a solid agent avatar. Activated when the active tab's
///   scroll view scrolls past the top.
///
/// Keeping it one stable view (instead of a conditional that the
/// `GlassEffectContainer` would morph) means a parent-applied
/// `.matchedTransitionSource(_:in:)` stays anchored to the visible glass
/// surface across the morph — sheets presented from the bar can zoom
/// out of the pill *or* the circle without their source anchor being
/// invalidated by a view-tree teardown.
struct AgentBuilderBar: View {
    let isExpanded: Bool
    let onTap: () -> Void
    let onTapPhotos: () -> Void
    let onTapCamera: () -> Void
    let onTapVoiceMemo: () -> Void
    /// Optional matched-transition source applied to the stable glass
    /// shape. When set, sheets presented after tapping the bar zoom out
    /// of whichever shape (pill or circle) is currently visible.
    var transitionSourceNamespace: Namespace.ID?
    var transitionSourceId: String?

    var body: some View {
        HStack(spacing: 0) {
            if !isExpanded {
                Spacer(minLength: 0)
            }
            glassShape
        }
        .animation(.smooth(duration: 0.25), value: isExpanded)
    }

    /// The stable glass capsule that morphs between the two visual
    /// states. Its frame width animates between `.infinity` (expanded)
    /// and `Constant.collapsedSize` (collapsed); its tint animates
    /// between clear (expanded) and black (collapsed). Both inner
    /// content layouts are always present and cross-faded via opacity,
    /// so the surrounding view tree stays identical across morphs.
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
            maxWidth: isExpanded ? .infinity : Constant.collapsedSize,
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

            attachmentButtonGroup
        }
        .padding(DesignConstants.Spacing.step3x)
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

    private var attachmentButtonGroup: some View {
        HStack(spacing: Constant.attachmentIconSpacing) {
            attachmentButton(systemImage: "photo.fill", label: "Add photo", action: onTapPhotos)
            attachmentButton(systemImage: "camera.fill", label: "Take photo", action: onTapCamera)
            attachmentButton(systemImage: "waveform", label: "Record voice memo", action: onTapVoiceMemo)
        }
        .padding(.horizontal, Constant.attachmentGroupHorizontalPadding)
    }

    private var agentAvatar: some View {
        ZStack {
            Circle()
                .fill(Color.black)
            Image("addAgentIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(width: Constant.avatarSize * 0.42, height: Constant.avatarSize * 0.42)
        }
        .frame(width: Constant.avatarSize, height: Constant.avatarSize)
        .accessibilityLabel("Make an agent")
    }

    private func attachmentButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.colorTextSecondary)
                .frame(width: Constant.attachmentIconWidth, height: Constant.attachmentIconHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private enum Constant {
        /// Height of both visual states. Picked to match the expanded
        /// capsule's natural height (32pt avatar + step3x*2 padding =
        /// 56pt) so the chrome's vertical footprint stays constant
        /// across the morph.
        static let barHeight: CGFloat = 56.0
        static let collapsedSize: CGFloat = 56.0
        static let collapsedIconSize: CGFloat = 24.0
        static let avatarSize: CGFloat = 32.0
        static let attachmentIconWidth: CGFloat = 20.0
        static let attachmentIconHeight: CGFloat = 18.0
        static let attachmentIconSpacing: CGFloat = 24.0
        static let attachmentGroupHorizontalPadding: CGFloat = 8.0
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
    AgentBuilderBar(
        isExpanded: true,
        onTap: {},
        onTapPhotos: {},
        onTapCamera: {},
        onTapVoiceMemo: {}
    )
    .padding()
    .background(Color.colorBackgroundSurfaceless)
}

#Preview("Collapsed") {
    AgentBuilderBar(
        isExpanded: false,
        onTap: {},
        onTapPhotos: {},
        onTapCamera: {},
        onTapVoiceMemo: {}
    )
    .padding()
    .background(Color.colorBackgroundSurfaceless)
}
