import SwiftUI

struct MessageReactionsView: View {
    @State var viewModel: MessageReactionMenuViewModel
    @State private var emojiAppeared: [Bool] = []
    @State private var showMoreAppeared: Bool = false
    @State private var customEmoji: String?
    @State private var popScale: CGFloat = 1.0

    init(viewModel: MessageReactionMenuViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var containerWidth: CGFloat {
        switch viewModel.viewState {
        case .collapsed, .minimized:
            Constant.height + (DesignConstants.Spacing.step4x)
        case .expanded:
            280.0
        case .compact:
            Constant.height * 2.0
        }
    }

    private var reactionsCapsule: some View {
        GeometryReader { reader in
            reactionsCapsuleContents(reader: reader)
        }
        .frame(width: containerWidth, height: Constant.height)
        .background(.colorBackgroundSurfaceless)
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.15), radius: 10.0, x: 0, y: 0)
        .scaleEffect(viewModel.viewState.isMinimized ? 0.0 : 1.0)
        .opacity(viewModel.viewState.isMinimized ? 0.0 : 1.0)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: viewModel.viewState)
        .onChange(of: viewModel.viewState) { lhs, _ in
            handleViewStateChange(from: lhs)
        }
    }

    private func reactionsCapsuleContents(reader: GeometryProxy) -> some View {
        let contentHeight = max(reader.size.height - (Constant.padding * 2.0), 0.0)
        return ZStack(alignment: .leading) {
            reactionsScrollView(reader: reader, contentHeight: contentHeight)
            HStack(spacing: 0.0) {
                Spacer()
                selectedEmojiView(reader: reader)
                expandCollapseButton(contentHeight: contentHeight)
            }
        }
        .padding(0.0)
        .animation(
            .spring(response: Constant.springResponse, dampingFraction: Constant.springDampingFractionPlus),
            value: viewModel.viewState
        )
    }

    private func handleViewStateChange(from previous: MessageReactionMenuViewModel.ViewState) {
        guard previous == .minimized else { return }
        if emojiAppeared.count != viewModel.reactions.count {
            emojiAppeared = Array(repeating: false, count: viewModel.reactions.count)
        }
        let totalDelay = Constant.emojiAppearanceDelay
            + (Constant.emojiAppearanceDelayStep * Double(viewModel.reactions.count))
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay) {
            withAnimation {
                showMoreAppeared = true
            }
        }
    }

    var body: some View {
        reactionsCapsule
            .frame(maxWidth: .infinity, alignment: viewModel.alignment)
            .background(.clear)
            .emojiPicker(
                isPresented: $viewModel.showingEmojiPicker,
                onPick: { emoji in
                    customEmoji = emoji
                    viewModel.add(reaction: .init(emoji: emoji, isSelected: true))
                },
                onDelete: {
                    customEmoji = nil
                }
            )
    }

    // MARK: - Subviews

    private func reactionButtonLabel(emoji: String, didAppear: Bool, hidesContent: Bool) -> some View {
        let blurAmount: CGFloat = hidesContent ? Constant.blurRadius : (didAppear ? 0.0 : Constant.blurRadius)
        let scale: CGFloat = hidesContent ? Constant.collapsedScale : (didAppear ? Constant.popScaleNormal : Constant.collapsedScale)
        let rotation: Double = didAppear ? 0 : Constant.emojiRotationCollapsed
        let opacity: CGFloat = hidesContent ? Constant.hiddenOpacity : Constant.visibleOpacity
        let spring: Animation = .spring(response: Constant.springResponse, dampingFraction: Constant.springDampingFractionCollapsed)
        return Text(emoji)
            .font(.system(size: Constant.emojiFontSize))
            .padding(Constant.padding)
            .blur(radius: blurAmount)
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation))
            .opacity(opacity)
            .animation(spring, value: hidesContent)
            .animation(spring, value: didAppear)
    }

    @ViewBuilder
    private func reactionButton(reaction: MessageReactionChoice, index: Int) -> some View {
        let didAppear: Bool = emojiAppeared.indices.contains(index) && emojiAppeared[index]
        let hidesContent: Bool = viewModel.viewState.hidesContent
        let noSelection: Bool = viewModel.selectedEmoji == nil

        Button {
            viewModel.add(reaction: reaction)
        } label: {
            reactionButtonLabel(emoji: reaction.emoji, didAppear: didAppear, hidesContent: hidesContent)
        }
        .disabled(hidesContent)
        .accessibilityLabel("React with \(reaction.emoji)")
        .scaleEffect(noSelection ? Constant.popScaleNormal : Constant.collapsedScale)
        .onChange(of: showMoreAppeared) {
            if emojiAppeared.indices.contains(index) && !emojiAppeared[index] {
                let delay: Double = Constant.emojiAppearanceDelayStep * Double(index)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation {
                        emojiAppeared[index] = true
                    }
                }
            }
        }
    }

    private func reactionsScrollView(reader: GeometryProxy, contentHeight: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0.0) {
                ForEach(Array(viewModel.reactions.enumerated()), id: \.element.id) { index, reaction in
                    reactionButton(reaction: reaction, index: index)
                }
            }
            .padding(.horizontal, Constant.padding)
        }
        .frame(height: reader.size.height)
        .contentMargins(.trailing, contentHeight, for: .scrollContent)
        .mask(
            HStack(spacing: 0) {
                // Left gradient
                LinearGradient(
                    gradient: Gradient(colors: [Constant.maskGradientTransparent, Constant.maskGradientColor]),
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: Constant.padding)
                // Middle
                Rectangle().fill(Constant.maskGradientColor)
                // Right gradient
                LinearGradient(
                    gradient: Gradient(colors: [Constant.maskGradientColor, Constant.maskGradientTransparent]),
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: (contentHeight * Constant.maskRightGradientMultiplier))
                // Right button area
                Rectangle().fill(Constant.maskClear)
                    .frame(width: contentHeight)
            }
        )
        .animation(
            .spring(response: Constant.springResponse, dampingFraction: Constant.springDampingFraction),
            value: viewModel.viewState
        )
    }

    private func selectedEmojiView(reader: GeometryProxy) -> some View {
        ZStack {
            Text(viewModel.selectedEmoji ?? customEmoji ?? "")
                .multilineTextAlignment(.center)
                .font(.system(size: Constant.selectedEmojiFontSize))
                .frame(width: Constant.selectedEmojiFrame, height: Constant.selectedEmojiFrame)
                .scaleEffect(
                    popScale * (
                        (viewModel.viewState.isCollapsed && customEmoji != nil) ||
                        viewModel.selectedEmoji != nil ? Constant.popScaleNormal : Constant.collapsedScale
                    )
                )
                .animation(
                    .spring(response: Constant.springResponse, dampingFraction: Constant.springDampingFraction),
                    value: customEmoji
                )
                .animation(
                    .spring(response: Constant.springResponse, dampingFraction: Constant.springDampingFraction),
                    value: viewModel.selectedEmoji
                )
                .onChange(of: viewModel.selectedEmoji ?? customEmoji ?? "") {
                    withAnimation(
                        .spring(response: Constant.springResponsePop,
                                dampingFraction: Constant.springDampingFractionPop)
                    ) {
                        popScale = Constant.popScaleLarge
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + Constant.popScaleDelay) {
                        withAnimation(
                            .spring(response: Constant.springResponse,
                                    dampingFraction: Constant.springDampingFraction)
                        ) {
                            popScale = Constant.popScaleNormal
                        }
                    }
                }

            Image(systemName: "face.smiling")
                .font(.system(size: Constant.faceSmilingFontSize))
                .tint(Constant.faceSmilingColor)
                .opacity(
                    (viewModel.viewState.isCompact && showMoreAppeared ?
                     Constant.faceSmilingOpacity : Constant.faceSmilingOpacityHidden)
                )
                .blur(
                    radius: (viewModel.viewState.isCompact && showMoreAppeared ?
                             Constant.faceSmilingOpacityHidden : Constant.blurRadius)
                )
                .rotationEffect(
                    .degrees(viewModel.viewState.isCompact ? 0.0 : Constant.faceSmilingRotationCollapsed)
                )
                .scaleEffect(
                    viewModel.viewState.isCompact && customEmoji == nil && viewModel.selectedEmoji == nil ?
                    Constant.popScaleNormal : Constant.collapsedScale
                )
                .animation(
                    .spring(response: Constant.springResponse, dampingFraction: Constant.springDampingFraction),
                    value: viewModel.viewState
                )
        }
        .frame(width: reader.size.height, height: reader.size.height)
    }

    private func expandCollapseButton(contentHeight: CGFloat) -> some View {
        Button {
            withAnimation(
                .spring(response: Constant.springResponse,
                        dampingFraction: Constant.springDampingFractionPlus)
            ) {
                switch viewModel.viewState {
                case .collapsed, .compact:
                    viewModel.viewState = .expanded
                case .expanded:
                    viewModel.viewState = .compact
                case .minimized:
                    break
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: Constant.plusIconFontSize))
                .padding(Constant.padding)
                .tint(Constant.plusIconColor)
                .offset(x: viewModel.viewState.isCollapsed || !showMoreAppeared ? Constant.plusOffset : 0.0)
                .opacity(
                    (viewModel.viewState.isCollapsed || !showMoreAppeared
                     ? Constant.hiddenOpacity : Constant.visibleOpacity)
                )
                .animation(
                    .spring(response: Constant.springResponse,
                            dampingFraction: Constant.springDampingFractionPlus),
                    value: viewModel.viewState
                )
                .rotationEffect(
                    .degrees(viewModel.viewState.isCompact ? Constant.plusRotationCollapsed : 0.0)
                )
        }
        .accessibilityLabel(viewModel.viewState.isCompact ? "Show more reactions" : "Show fewer reactions")
        .accessibilityIdentifier("reactions-expand-collapse")
        .frame(minWidth: contentHeight)
        .padding(.trailing, Constant.plusTrailingPadding)
        .scaleEffect(
            viewModel.selectedEmoji == nil ? Constant.popScaleNormal : Constant.collapsedScale
        )
        .animation(
            .spring(response: Constant.springResponse, dampingFraction: Constant.springDampingFraction),
            value: viewModel.viewState
        )
    }

    private enum Constant {
        static let height: CGFloat = 56.0
        static let padding: CGFloat = 8.0
        static let emojiAppearanceDelay: TimeInterval = 0.0
        static let emojiAppearanceDelayStep: TimeInterval = 0.05
        static let emojiFontSize: CGFloat = 24.0
        static let selectedEmojiFontSize: CGFloat = 28.0
        static let selectedEmojiFrame: CGFloat = 32.0
        static let blurRadius: CGFloat = 10.0
        static let emojiRotationCollapsed: Double = -15
        static let faceSmilingRotationCollapsed: Double = -30.0
        static let plusRotationCollapsed: Double = -45.0
        static let plusOffset: CGFloat = 40
        static let plusTrailingPadding: CGFloat = 8.0
        static let faceSmilingOpacity: Double = 0.2
        static let faceSmilingOpacityHidden: Double = 0.0
        static let visibleOpacity: Double = 1.0
        static let hiddenOpacity: Double = 0.0
        static let popScaleDelay: TimeInterval = 0.15
        static let popScaleLarge: CGFloat = 1.2
        static let popScaleNormal: CGFloat = 1.0
        static let collapsedScale: CGFloat = 0.0
        static let springResponse: Double = 0.4
        static let springDampingFraction: Double = 0.8
        static let springDampingFractionCollapsed: Double = 0.6
        static let springDampingFractionPlus: Double = 0.7
        static let springResponsePop: Double = 0.2
        static let springDampingFractionPop: Double = 0.5
        static let maskRightGradientMultiplier: CGFloat = 0.3
        static let backgroundColor: Color = Color.gray.opacity(0.1)
        static let maskGradientColor: Color = Color.black
        static let maskGradientTransparent: Color = Color.black.opacity(0)
        static let plusIconFontSize: CGFloat = 24.0
        static let faceSmilingFontSize: CGFloat = 28.0
        static let plusIconColor: Color = .colorTextSecondary
        static let faceSmilingColor: Color = .black
        static let maskClear: Color = .clear
    }
}

#Preview {
    @Previewable @State var viewModel: MessageReactionMenuViewModel = .init()
    VStack {
        HStack {
            MessageReactionsView(viewModel: viewModel)
        }
        .frame(width: .infinity, alignment: .trailing)
        .onAppear {
            viewModel.viewState = .expanded
        }
        Button {
            viewModel.selectedEmoji = nil
            viewModel.viewState = .minimized
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation {
                    viewModel.viewState = .expanded
                }
            }
        } label: {
            Text("Reset")
        }
    }
}
