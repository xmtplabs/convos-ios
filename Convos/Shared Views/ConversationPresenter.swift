import ConvosCore
import SwiftUI

struct ConversationPresenter<Content: View>: View {
    let viewModel: ConversationViewModel?
    let focusCoordinator: FocusCoordinator
    let insetsTopSafeArea: Bool
    var isReadOnly: Bool = false
    @Binding var sidebarColumnWidth: CGFloat
    /// Overrides the indicator's placeholder name (otherwise falls back to
    /// `ConversationViewModel.untitledConversationPlaceholder`). Used by
    /// flows where the underlying conversation is a draft and the indicator
    /// wants a flow-specific label (e.g. "New agent").
    var indicatorPlaceholderOverride: String?
    /// Overrides the indicator's subtitle (otherwise falls back to
    /// `ConversationViewModel.conversationInfoSubtitle`). E.g. "Draft" for
    /// the agent builder.
    var indicatorSubtitleOverride: String?
    /// When false, taps still register on the indicator (so the liquid-glass
    /// touch feedback fires) but the expand-to-QuickEditor and info-view
    /// actions are no-ops. Used in draft flows where the conversation isn't
    /// the user's to edit yet — the visual affordance stays alive.
    var allowsIndicatorEditing: Bool = true
    /// Replaces `FocusCoordinator.defaultFocus` for the `task(id:)` reset
    /// that fires whenever the conversation id changes. Lets flows like the
    /// Agent Builder pin focus on their composer field even after the
    /// underlying conversation flips from `draft-...` to a real XMTP id.
    var defaultFocusOverride: MessagesViewInputFocus?
    /// Context for the leading app-mode indicator. When non-nil and there
    /// is no conversation `viewModel` in focus, the presenter renders an
    /// [[AppIndicatorPill]] at the top-leading edge in place of the
    /// centered conversation pill. Pass nil to suppress the leading pill
    /// (used by surfaces that don't want any app-level chrome, e.g. the
    /// share overlay).
    var appIndicatorContext: AppIndicatorContext?
    /// Shared namespace for the AppIndicatorPill ↔ centered conversation
    /// indicator matched-geometry effect when those two surfaces aren't
    /// in the same view subtree (the pill is rendered once at the
    /// `MainTabView` level and morphs into a per-tab presenter's
    /// centered conv pill on selection). Falls back to the presenter's
    /// private namespace when nil.
    var sharedIndicatorNamespace: Namespace.ID?
    /// When `false`, the presenter skips rendering its centered
    /// conversation-indicator overlay. Used by hosts that lift the
    /// indicator to a parent surface (e.g. `MainTabView` showing the
    /// pill ↔ conv-indicator morph in a single overlay outside the
    /// `NavigationStack`) so both branches share one SwiftUI animation
    /// context. Focus and share-overlay handling stay active either way.
    var rendersConversationIndicator: Bool = true
    @ViewBuilder let content: (FocusState<MessagesViewInputFocus?>.Binding, FocusCoordinator) -> Content

    @FocusState private var focusState: MessagesViewInputFocus?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @Environment(\.safeAreaInsets) private var safeAreaInsets: EdgeInsets
    /// Pairs the leading [[AppIndicatorPill]] with the centered conversation
    /// indicator so that when `viewModel` flips from nil to non-nil, the
    /// outer capsule animates its frame from top-leading to top-center
    /// instead of cross-fading in place. Inner content (avatar / title /
    /// subtitle) uses `.blurReplace` for the swap, which combines a soft
    /// blur with opacity for a smooth crossfade against the morphing
    /// capsule. The `.bouncy(duration: 0.4, extraBounce: 0.15)` animation
    /// the surrounding VStack carries on `viewModel != nil` drives both
    /// the matched-geometry interpolation and the blur transition.
    @Namespace private var indicatorNamespace: Namespace.ID

    private var isShowingShareOverlay: Bool {
        guard let viewModel else { return false }
        return viewModel.presentingShareView
    }

    var body: some View {
        ZStack {
            content($focusState, focusCoordinator)
                .toolbar(isShowingShareOverlay ? .hidden : .automatic, for: .navigationBar)

            VStack {
                indicatorOverlay
                Spacer()
            }
            .animation(.bouncy(duration: 0.4, extraBounce: 0.15), value: viewModel != nil)
            .ignoresSafeArea()
            .allowsHitTesting(true)
            .zIndex(1000)

            if let viewModel, viewModel.presentingShareView {
                ConversationShareOverlay(
                    conversation: viewModel.conversation,
                    invite: viewModel.invite,
                    isPresented: Binding(
                        get: { viewModel.presentingShareView },
                        set: { viewModel.presentingShareView = $0 }
                    ),
                    topSafeAreaInset: insetsTopSafeArea && horizontalSizeClass == .compact ? safeAreaInsets.top : DesignConstants.Spacing.step3x
                )
                .ignoresSafeArea()
                .zIndex(2000)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onAppear {
            // Update coordinator's horizontal size class on appear
            focusCoordinator.horizontalSizeClass = horizontalSizeClass
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            // Update coordinator's horizontal size class when it changes
            focusCoordinator.horizontalSizeClass = newSizeClass
        }
        .onChange(of: focusCoordinator.currentFocus) { oldFocus, newFocus in
            Log.info("onChange(of: focusCoordinator.currentFocus) oldFocus: \(String(describing: oldFocus)) newFocus: \(String(describing: newFocus))")
            // Always sync coordinator to SwiftUI to ensure focus actually changes
            // The transition flags will prevent race conditions in the opposite direction
            focusState = newFocus
        }
        .onChange(of: focusState) { _, newFocus in
            // Delegate all synchronization logic to the coordinator
            focusCoordinator.syncFocusState(newFocus)
        }
        .task(id: viewModel?.conversation.id) {
            // Set default focus when conversation changes
            focusState = defaultFocusOverride ?? focusCoordinator.defaultFocus
        }
    }

    private var indicatorTopInset: CGFloat {
        if insetsTopSafeArea && horizontalSizeClass == .compact {
            return safeAreaInsets.top
        }
        return DesignConstants.Spacing.step3x
    }

    private var indicatorLeadingInset: CGFloat {
        horizontalSizeClass != .compact ? sidebarColumnWidth : 0.0
    }

    @ViewBuilder
    private var indicatorOverlay: some View {
        if let viewModel = viewModel, viewModel.showsInfoView, !isShowingShareOverlay, rendersConversationIndicator {
            conversationIndicatorView(for: viewModel)
        } else if viewModel == nil, !isShowingShareOverlay, let appContext = appIndicatorContext {
            appIndicatorView(for: appContext)
        }
    }

    @ViewBuilder
    private func conversationIndicatorView(for viewModel: ConversationViewModel) -> some View {
        let pendingAgentOverride: AgentVerification? = viewModel.shouldRenderAsPendingAgent
            ? .verified(.convos)
            : nil
        ConversationIndicatorWrapper(
            viewModel: viewModel,
            placeholderOverride: indicatorPlaceholderOverride,
            subtitleOverride: indicatorSubtitleOverride,
            allowsEditing: allowsIndicatorEditing && !isReadOnly,
            focusState: $focusState,
            focusCoordinator: focusCoordinator
        )
        .environment(\.forcedAgentVerification, pendingAgentOverride)
        .hoverEffect(.lift)
        .disabled(isReadOnly)
        .matchedGeometryEffect(
            id: AdaptiveAppIndicatorConstant.indicatorShellId,
            in: sharedIndicatorNamespace ?? indicatorNamespace,
            properties: .position
        )
        .padding(.top, indicatorTopInset)
        .padding(.leading, indicatorLeadingInset)
        .transition(.blurReplace)
    }

    @ViewBuilder
    private func appIndicatorView(for context: AppIndicatorContext) -> some View {
        HStack {
            appIndicatorPill(for: context)
                .hoverEffect(.lift)
                .matchedGeometryEffect(
            id: AdaptiveAppIndicatorConstant.indicatorShellId,
            in: indicatorNamespace,
            properties: .position
        )
            Spacer(minLength: 0)
        }
        .padding(.top, indicatorTopInset)
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.leading, indicatorLeadingInset)
        .transition(.blurReplace)
    }

    @ViewBuilder
    private func appIndicatorPill(for context: AppIndicatorContext) -> some View {
        let pill = AppIndicatorPill(
            profileImage: context.profileImage,
            title: context.title,
            subtitle: context.subtitle,
            action: context.onTap
        )
        if let namespace = context.transitionNamespace, let id = context.transitionId {
            pill.matchedTransitionSource(id: id, in: namespace)
        } else {
            pill
        }
    }
}

enum AdaptiveAppIndicatorConstant {
    static let indicatorShellId: String = "adaptive-app-indicator-shell"
}

struct ConversationIndicatorWrapper: View {
    @Bindable var viewModel: ConversationViewModel
    let placeholderOverride: String?
    let subtitleOverride: String?
    let allowsEditing: Bool
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator

    var body: some View {
        ConversationIndicator(
            conversation: viewModel.conversation,
            placeholderName: viewModel.conversationNamePlaceholder,
            untitledConversationPlaceholder: placeholderOverride ?? viewModel.untitledConversationPlaceholder,
            subtitle: subtitleOverride ?? viewModel.conversationInfoSubtitle,
            scheduledExplosionDate: viewModel.scheduledExplosionDate,
            conversationName: $viewModel.editingConversationName,
            conversationImage: $viewModel.conversationImage,
            presentingConversationSettings: $viewModel.presentingConversationSettings,
            activeToast: $viewModel.activeToast,
            autoRevealPhotos: Binding(
                get: { viewModel.autoRevealPhotos },
                set: { viewModel.setAutoReveal($0) }
            ),
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            showsExplodeNowButton: viewModel.showsExplodeNowButton,
            explodeState: viewModel.explodeState,
            onConversationInfoTapped: {
                guard allowsEditing else { return }
                viewModel.onConversationInfoTap(focusCoordinator: focusCoordinator)
            },
            onConversationInfoLongPressed: {
                guard allowsEditing else { return }
                viewModel.onConversationInfoLongPress(focusCoordinator: focusCoordinator)
            },
            onConversationNameEndedEditing: {
                viewModel.onConversationNameEndedEditing(
                    focusCoordinator: focusCoordinator,
                    context: .quickEditor
                )
            },
            onConversationSettings: { viewModel.onConversationSettings(focusCoordinator: focusCoordinator) },
            onExplodeNow: viewModel.explodeConvo,
            infoView: {
                ConversationInfoView(viewModel: viewModel, focusCoordinator: focusCoordinator)
            }
        )
    }
}

@MainActor
private func makePresenterPreviewViewModel() -> ConversationViewModel? {
    .mock
}

#Preview {
    @Previewable @State var conversationViewModel: ConversationViewModel? = makePresenterPreviewViewModel()
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    @Previewable @State var sidebarColumnWidth: CGFloat = 0
    ConversationPresenter(
        viewModel: conversationViewModel,
        focusCoordinator: focusCoordinator,
        insetsTopSafeArea: false,
        sidebarColumnWidth: $sidebarColumnWidth
    ) { _, _ in
        EmptyView()
    }
    .withSafeAreaEnvironment()
}
