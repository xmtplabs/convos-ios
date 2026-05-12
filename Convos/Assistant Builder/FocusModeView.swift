import ConvosCore
import SwiftUI

/// The two-region focus canvas. Top half is the focused member's read-only
/// live bubble; bottom half is the user's editor + (when present) an
/// other-members slot stacked between them.
///
/// All state derives from the view-model — this view stays presentation-only
/// so the layout transitions ride a single shared animation.
struct FocusModeView: View {
    @Bindable var viewModel: AssistantBuilderViewModel
    @State private var isComposing: Bool = false

    @State private var pendingReadReceiptTask: Task<Void, Never>?

    /// Cached "loudest other typer" so quick gaps in the streaming snapshot
    /// (a frame where every live bubble has empty text) don't make the
    /// avatar flicker out from under the bubble. We only update this when
    /// the view-model gives us a *non-nil* candidate; the slot's `.hidden`
    /// case is what removes the avatar from the layout.
    @State private var stickyOtherAvatarMember: ConversationMember?

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                topRegion
                    .frame(height: topRegionHeight(in: proxy.size))
                    .padding(.bottom, DesignConstants.Spacing.step3x)
                bottomRegion
                    .frame(maxHeight: .infinity)
                readReceiptRow
                    .frame(height: readReceiptRowHeight)
            }
            .padding(.top, DesignConstants.Spacing.stepX)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .padding(.bottom, DesignConstants.Spacing.step3x)
            .animation(layoutAnimation, value: layout)
        }
        .onAppear {
            isComposing = true
            updateStickyAvatarIfNeeded()
        }
        .onChange(of: viewModel.phase) { _, newPhase in
            isComposing = phaseAllowsComposing(newPhase)
        }
        .onChange(of: viewModel.firstActiveOtherMember?.profile.id) { _, _ in
            updateStickyAvatarIfNeeded()
        }
        .onChange(of: othersFullBubbleKey) { _, newKey in
            scheduleReadReceiptIfNeeded(for: newKey)
        }
        .onAppear {
            scheduleReadReceiptIfNeeded(for: othersFullBubbleKey)
        }
        .onDisappear {
            pendingReadReceiptTask?.cancel()
            pendingReadReceiptTask = nil
        }
    }

    /// Snapshot key that's non-nil only while another member's full-mode
    /// bubble is on screen with text. When this changes (text changes, hides,
    /// or appears), the read-receipt timer is rescheduled.
    private var othersFullBubbleKey: String? {
        guard layout.othersSlot == .full else { return nil }
        let text = viewModel.othersLiveText
        guard !text.isEmpty else { return nil }
        return text
    }

    private func scheduleReadReceiptIfNeeded(for key: String?) {
        pendingReadReceiptTask?.cancel()
        pendingReadReceiptTask = nil
        guard key != nil else { return }
        pendingReadReceiptTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                viewModel.sendFocusReadReceiptIfNeeded()
            }
        }
    }

    // MARK: - Regions

    @ViewBuilder
    private var topRegion: some View {
        let endSessionDebugAction = { viewModel.debugEndFocusSession() }
        let isWaiting: Bool = viewModel.isWaitingForAssistant
        let displayText: String = isWaiting
            ? "Assistant is joining…"
            : viewModel.focusedMemberLiveText
        let focusedSize: LiveBubbleSize = focusedIsRested ? .singleLine : .full
        LiveBubble(
            text: displayText,
            style: .focusedMember,
            tailCorner: .topTrailing,
            agentVerification: viewModel.assistantVerification,
            size: focusedSize,
            isPlaceholder: isWaiting
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .matchedGeometryEffect(id: "focused-bubble", in: focusNamespace)
        .onLongPressGesture(minimumDuration: 1.5, perform: endSessionDebugAction)
    }

    @ViewBuilder
    private var bottomRegion: some View {
        HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step3x) {
            if layout.othersSlot != .hidden {
                othersSlotView
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            localSlotView
        }
    }

    @ViewBuilder
    private var readReceiptRow: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            Spacer()
            if !viewModel.readByMembers.isEmpty {
                Text("Read")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                ReadReceiptAvatarsView(members: viewModel.readByMembers)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.easeInOut(duration: 0.2), value: viewModel.readByMembers)
    }

    private var readReceiptRowHeight: CGFloat {
        24
    }

    @ViewBuilder
    private var othersSlotView: some View {
        if layout.othersSlot != .hidden {
            HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step2x) {
                othersAvatar
                    .matchedGeometryEffect(id: "others-avatar", in: focusNamespace)
                othersBubbleContent
                    .matchedGeometryEffect(id: "others-bubble", in: focusNamespace)
            }
            .id("others-slot")
        }
    }

    @ViewBuilder
    private var othersBubbleContent: some View {
        switch layout.othersSlot {
        case .hidden:
            EmptyView()
        case .full:
            LiveBubble(
                text: viewModel.othersLiveText,
                style: .otherMember,
                tailCorner: .bottomLeading,
                size: .full
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .compactAnimatedDots:
            TypingDotsBubble(
                dotState: .animated,
                avatarMember: nil,
                style: .otherMember,
                tailCorner: .bottomLeading
            )
            .frame(width: compactPillWidth - 28 - DesignConstants.Spacing.step2x, height: compactBubbleHeight)
        }
    }

    @ViewBuilder
    private var othersAvatar: some View {
        if let member = stickyOtherAvatarMember ?? viewModel.firstActiveOtherMember {
            AvatarView(
                fallbackName: member.profile.displayName,
                cacheableObject: member.profile,
                placeholderImage: nil,
                placeholderImageName: nil,
                agentVerification: member.agentVerification
            )
            .frame(width: 28, height: 28)
            .clipShape(Circle())
            .id("others-avatar-\(member.profile.id)")
        }
    }

    private func updateStickyAvatarIfNeeded() {
        guard let current = viewModel.firstActiveOtherMember else { return }
        stickyOtherAvatarMember = current
    }

    @ViewBuilder
    private var localSlotView: some View {
        let isCompact: Bool = layout.localSlot != .full
        let editorSize: LiveBubbleSize = isCompact ? .singleLine : .full
        let maxFrameWidth: CGFloat = isCompact ? compactPillWidth : .infinity
        let maxFrameHeight: CGFloat = isCompact ? compactBubbleHeight : .infinity
        let submitAndKeepFocus: () -> Void = {
            viewModel.handleReturnPressed()
            DispatchQueue.main.async {
                isComposing = true
            }
        }
        LiveBubbleEditor(
            text: $viewModel.draftText,
            placeholder: "Type something",
            tailCorner: .bottomTrailing,
            onSubmit: submitAndKeepFocus,
            isFocusedExternally: $isComposing,
            size: editorSize
        )
        .frame(maxWidth: maxFrameWidth, maxHeight: maxFrameHeight)
        .matchedGeometryEffect(id: "user-bubble", in: focusNamespace)
    }

    // MARK: - Layout derivation

    private var layout: FocusRegionLayout {
        FocusRegionLayout.resolve(
            focusedTyping: !viewModel.focusedMemberLiveText.isEmpty,
            local: viewModel.localActivity,
            others: viewModel.othersActivity
        )
    }

    private var focusedIsRested: Bool {
        // Focused bubble collapses to single-line when the local user or any
        // other member is the active typer (per locked layout rules).
        let focusedHasText = !viewModel.focusedMemberLiveText.isEmpty
        let someoneElseActive = viewModel.localActivity == .active || viewModel.othersActivity == .active
        return focusedHasText && someoneElseActive
    }

    private var compactBubbleHeight: CGFloat {
        56
    }

    private var compactPillWidth: CGFloat {
        110
    }

    private func topRegionHeight(in size: CGSize) -> CGFloat {
        let usable = max(size.height - DesignConstants.Spacing.step6x, 0)
        return usable * layout.topFraction
    }

    private var layoutAnimation: Animation {
        .spring(response: 0.45, dampingFraction: 0.85)
    }

    private func phaseAllowsComposing(_ phase: AssistantBuilderViewModel.Phase) -> Bool {
        switch phase {
        case .bootstrap, .focus: return true
        case .stopped: return false
        }
    }

    @Namespace private var focusNamespace
}
