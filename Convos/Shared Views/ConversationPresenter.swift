import SwiftUI

struct ConversationPresenter<Content: View>: View {
    let viewModel: ConversationViewModel?
    let focusCoordinator: FocusCoordinator
    let insetsTopSafeArea: Bool
    @Binding var sidebarColumnWidth: CGFloat
    @ViewBuilder let content: (FocusState<MessagesViewInputFocus?>.Binding, FocusCoordinator) -> Content

    @FocusState private var focusState: MessagesViewInputFocus?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @Environment(\.safeAreaInsets) private var safeAreaInsets: EdgeInsets

    var body: some View {
        ZStack {
            content($focusState, focusCoordinator)

            VStack {
                if let viewModel = viewModel, viewModel.showsInfoView {
                    ConversationInfoButtonWrapper(
                        viewModel: viewModel,
                        focusState: $focusState,
                        focusCoordinator: focusCoordinator
                    )
                    .hoverEffect(.lift)
                    .padding(.top, insetsTopSafeArea ? safeAreaInsets.top : DesignConstants.Spacing.step3x)
                    .padding(.leading, horizontalSizeClass != .compact ? sidebarColumnWidth : 0.0)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .identity
                    ))
                }

                Spacer()
            }
            .animation(.bouncy(duration: 0.4, extraBounce: 0.15), value: viewModel != nil)
            .ignoresSafeArea()
            .allowsHitTesting(true)
            .zIndex(1000)
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
            focusState = focusCoordinator.defaultFocus
        }
    }
}

private struct ConversationInfoButtonWrapper: View {
    @Bindable var viewModel: ConversationViewModel
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator

    var body: some View {
        ConversationInfoButton(
            conversation: viewModel.conversation,
            placeholderName: viewModel.conversationNamePlaceholder,
            untitledConversationPlaceholder: viewModel.untitledConversationPlaceholder,
            subtitle: viewModel.conversationInfoSubtitle,
            conversationName: $viewModel.editingConversationName,
            conversationImage: $viewModel.conversationImage,
            presentingConversationSettings: $viewModel.presentingConversationSettings,
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            showsExplodeNowButton: viewModel.showsExplodeNowButton,
            explodeState: viewModel.explodeState,
            onConversationInfoTapped: { viewModel.onConversationInfoTap(focusCoordinator: focusCoordinator) },
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

#Preview {
    @Previewable @State var conversationViewModel: ConversationViewModel? = .mock
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
