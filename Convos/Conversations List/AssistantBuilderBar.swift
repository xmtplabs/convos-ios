import SwiftUI

/// Bottom-accessory bar above the iOS 26 floating tab bar that lets the
/// user kick off an assistant-builder draft without opening the full
/// `AssistantBuilderView` first. Two states wrapped in a single
/// `GlassEffectContainer` so the glass surface morphs between them:
///
/// - **Expanded**: a full-width capsule with the "A" agent avatar on the
///   leading edge, a "Make an agent" placeholder label, and three trailing
///   icon buttons for photo picker / camera / voice memo entry points.
///   Tapping the body opens the builder with text focused. Tapping an
///   icon opens it pre-loaded with the matching attachment intent.
///
/// - **Collapsed**: just the agent avatar floating at the trailing edge,
///   in the slot the search-tab icon occupies in the tab bar. Activated
///   when either the Chats or Stuff list scrolls past the top so the
///   composer doesn't fight the user's scroll position.
///
/// The morph between the two states is owned by `GlassEffectContainer` +
/// `glassEffectID(_:in:)` — the glass material interpolates between the
/// capsule and the circle and the inner contents cross-fade via
/// `.blurReplace`. The animation timing matches the rest of the chrome
/// (`.bouncy(duration: 0.4, extraBounce: 0.15)`).
struct AssistantBuilderBar: View {
    let isExpanded: Bool
    let onTap: () -> Void
    let onTapPhotos: () -> Void
    let onTapCamera: () -> Void
    let onTapVoiceMemo: () -> Void

    @Namespace private var morphNamespace

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            if isExpanded {
                expandedBar
                    .glassEffectID(Constant.surfaceId, in: morphNamespace)
                    .transition(.blurReplace)
            } else {
                collapsedBar
                    .glassEffectID(Constant.surfaceId, in: morphNamespace)
                    .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.25), value: isExpanded)
    }

    private var expandedBar: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            assistantAvatar

            Text("Make an agent")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            attachmentButtonGroup
        }
        .padding(DesignConstants.Spacing.step3x)
        .frame(maxWidth: .infinity)
        .contentShape(.capsule)
        .onTapGesture(perform: onTap)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant-builder-bar-expanded")
    }

    private var attachmentButtonGroup: some View {
        HStack(spacing: Constant.attachmentIconSpacing) {
            attachmentButton(systemImage: "photo.fill", label: "Add photo", action: onTapPhotos)
            attachmentButton(systemImage: "camera.fill", label: "Take photo", action: onTapCamera)
            attachmentButton(systemImage: "waveform", label: "Record voice memo", action: onTapVoiceMemo)
        }
        .padding(.horizontal, Constant.attachmentGroupHorizontalPadding)
    }

    private var collapsedBar: some View {
        HStack {
            Spacer()
            collapsedGlassCircle
        }
        .accessibilityIdentifier("assistant-builder-bar-collapsed")
    }

    /// Black-tinted liquid-glass circle that fills the same vertical
    /// extent as the expanded capsule so the chrome's overall height
    /// stays constant across the morph. The `GlassEffectContainer`
    /// interpolates the surface shape (capsule -> circle) and tint via
    /// the shared `glassEffectID`.
    private var collapsedGlassCircle: some View {
        Button(action: onTap) {
            Image("addAssistantIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(width: Constant.collapsedIconSize, height: Constant.collapsedIconSize)
                .frame(width: Constant.collapsedCircleSize, height: Constant.collapsedCircleSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.black).interactive(), in: .circle)
        .accessibilityLabel("Make an agent")
        .accessibilityIdentifier("assistant-builder-bar-avatar")
    }

    private var assistantAvatar: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(Color.black)
                Image("addAssistantIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: Constant.avatarSize * 0.42, height: Constant.avatarSize * 0.42)
            }
            .frame(width: Constant.avatarSize, height: Constant.avatarSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Make an agent")
        .accessibilityIdentifier("assistant-builder-bar-avatar")
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
        static let surfaceId: String = "assistant-builder-bar-glass"
        static let avatarSize: CGFloat = 32
        /// Diameter of the collapsed-state glass circle. Matches the
        /// expanded capsule's height (32pt avatar + step3x*2 padding =
        /// 32 + 24 = 56pt) so the chrome's overall vertical footprint
        /// stays constant across the expanded -> collapsed morph,
        /// avoiding a layout shift that would oscillate the scroll
        /// position.
        static let collapsedCircleSize: CGFloat = 56.0
        static let collapsedIconSize: CGFloat = 24.0
        static let attachmentIconWidth: CGFloat = 20.0
        static let attachmentIconHeight: CGFloat = 18.0
        static let attachmentIconSpacing: CGFloat = 24.0
        static let attachmentGroupHorizontalPadding: CGFloat = 8.0
    }
}

#Preview("Expanded") {
    AssistantBuilderBar(
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
    AssistantBuilderBar(
        isExpanded: false,
        onTap: {},
        onTapPhotos: {},
        onTapCamera: {},
        onTapVoiceMemo: {}
    )
    .padding()
    .background(Color.colorBackgroundSurfaceless)
}
