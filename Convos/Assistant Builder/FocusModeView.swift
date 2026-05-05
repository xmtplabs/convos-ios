import ConvosCore
import SwiftUI

/// The two-region focus canvas. Top half is the focused member's read-only
/// live bubble; bottom half is the user's editor (and, when others are
/// active, a chorus bubble for them).
///
/// All state derives from the view-model — this view stays presentation-only
/// so the layout transitions ride a single shared animation.
struct FocusModeView: View {
    @Bindable var viewModel: AssistantBuilderViewModel
    @FocusState private var isComposing: Bool

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: DesignConstants.Spacing.step3x) {
                topRegion
                    .frame(height: topRegionHeight(in: proxy.size))
                bottomRegion
                    .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .padding(.bottom, DesignConstants.Spacing.step3x)
            .animation(layoutAnimation, value: layout)
        }
        .onAppear { isComposing = true }
        .onChange(of: viewModel.phase) { _, newPhase in
            isComposing = (newPhase == .focus)
        }
    }

    // MARK: - Regions

    @ViewBuilder
    private var topRegion: some View {
        LiveBubble(
            text: viewModel.focusedMemberLiveText,
            style: .focusedMember,
            tailCorner: .topTrailing
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .matchedGeometryEffect(id: "focused-bubble", in: focusNamespace)
    }

    @ViewBuilder
    private var bottomRegion: some View {
        switch layout.bottomLayout {
        case .userOnly:
            userBubble
        case .othersOnly:
            othersBubble
        case .split(let userFraction):
            HStack(spacing: DesignConstants.Spacing.step3x) {
                othersBubble
                    .frame(maxWidth: .infinity)
                userBubble
                    .frame(maxWidth: .infinity)
                    .layoutPriority(userFraction > 0.5 ? 1 : -1)
            }
        }
    }

    @ViewBuilder
    private var userBubble: some View {
        LiveBubbleEditor(
            text: $viewModel.draftText,
            placeholder: "Type something",
            tailCorner: .bottomTrailing,
            onSubmit: viewModel.handleReturnPressed,
            isFocusedExternally: $isComposing
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .matchedGeometryEffect(id: "user-bubble", in: focusNamespace)
    }

    @ViewBuilder
    private var othersBubble: some View {
        LiveBubble(
            text: viewModel.othersLiveText,
            style: .otherMember,
            tailCorner: .bottomLeading
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .matchedGeometryEffect(id: "others-bubble", in: focusNamespace)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    // MARK: - Layout derivation

    private var layout: FocusRegionLayout {
        FocusRegionLayout.resolve(
            userTyping: !viewModel.draftText.isEmpty,
            othersTyping: viewModel.othersAreTyping,
            othersJustStopped: viewModel.othersRecentlyStopped
        )
    }

    private func topRegionHeight(in size: CGSize) -> CGFloat {
        let usable = max(size.height - DesignConstants.Spacing.step6x, 0)
        return usable * layout.topFraction
    }

    private var layoutAnimation: Animation {
        .spring(response: 0.45, dampingFraction: 0.85)
    }

    @Namespace private var focusNamespace
}
