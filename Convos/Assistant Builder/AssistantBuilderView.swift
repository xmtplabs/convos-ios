import ConvosCore
import SwiftUI

struct AssistantBuilderView: View {
    @Bindable var viewModel: AssistantBuilderViewModel
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    @State private var sidebarWidth: CGFloat = 0
    @State private var presentingDiscardConfirmation: Bool = false

    private var indicatorPlaceholder: String? {
        viewModel.hasCommitted ? nil : "New assistant"
    }

    private var indicatorSubtitle: String? {
        viewModel.hasCommitted ? nil : "Draft"
    }

    var body: some View {
        ConversationPresenter(
            viewModel: viewModel.newConversationViewModel.conversationViewModel,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: false,
            sidebarColumnWidth: $sidebarWidth,
            indicatorPlaceholderOverride: indicatorPlaceholder,
            indicatorSubtitleOverride: indicatorSubtitle,
            allowsIndicatorEditing: viewModel.hasCommitted
        ) { focusState, coordinator in
            NavigationStack {
                ZStack {
                    underlyingConversationView(focusState: focusState, coordinator: coordinator)

                    if !viewModel.hasCommitted {
                        composerOverlay(focusState: focusState)
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .move(edge: .bottom)
                                    .combined(with: .opacity)
                                    .combined(with: .scale(scale: 0.85, anchor: .bottom))
                            ))
                            .zIndex(1)
                    }
                }
                .animation(.spring(response: 0.42, dampingFraction: 0.85), value: viewModel.hasCommitted)
                .toolbar {
                    closeToolbarItem
                }
                .toolbarTitleDisplayMode(.inline)
                .onAppear {
                    coordinator.moveFocus(to: .message)
                }
            }
        }
        .onAppear {
            focusCoordinator.horizontalSizeClass = horizontalSizeClass
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            focusCoordinator.horizontalSizeClass = newSizeClass
        }
    }

    @ViewBuilder
    private func underlyingConversationView(
        focusState: FocusState<MessagesViewInputFocus?>.Binding,
        coordinator: FocusCoordinator
    ) -> some View {
        if let convoVM = viewModel.newConversationViewModel.conversationViewModel {
            ConversationView(
                viewModel: convoVM,
                profileSettingsViewModel: profileSettingsViewModel,
                focusState: focusState,
                focusCoordinator: coordinator,
                onScanInviteCode: {},
                onDeleteConversation: {
                    viewModel.discard()
                    dismiss()
                },
                messagesTopBarTrailingItem: viewModel.newConversationViewModel.messagesTopBarTrailingItem,
                messagesTopBarTrailingItemEnabled: viewModel.newConversationViewModel.messagesTopBarTrailingItemEnabled,
                messagesTextFieldEnabled: viewModel.newConversationViewModel.messagesTextFieldEnabled,
                bottomBarContent: { EmptyView() }
            )
        } else {
            Color.colorBackgroundRaisedSecondary
        }
    }

    private func composerOverlay(
        focusState: FocusState<MessagesViewInputFocus?>.Binding
    ) -> some View {
        VStack(spacing: 0) {
            AssistantDraftComposer(
                viewModel: viewModel,
                focusState: focusState,
                onMakeTap: {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        viewModel.commit()
                    }
                }
            )
            .frame(height: Constant.composerHeight)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.top, DesignConstants.Spacing.step4x)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.colorBackgroundRaisedSecondary.ignoresSafeArea())
    }

    @ToolbarContentBuilder
    private var closeToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(role: .close) {
                handleCloseTapped()
            }
            .confirmationDialog(
                "",
                isPresented: $presentingDiscardConfirmation
            ) {
                Button("Discard", role: .destructive) {
                    viewModel.discard()
                    dismiss()
                }
                Button("Continue") {}
            }
            .accessibilityIdentifier("close-assistant-builder")
        }
    }

    private func handleCloseTapped() {
        if viewModel.hasCommitted {
            dismiss()
        } else if viewModel.hasContent {
            presentingDiscardConfirmation = true
        } else {
            viewModel.discard()
            dismiss()
        }
    }

    private enum Constant {
        static let composerHeight: CGFloat = 375.0
    }
}

#Preview {
    @Previewable @State var viewModel: AssistantBuilderViewModel = .init(
        session: ConvosClient.mock().session
    )
    @Previewable @State var profileSettingsViewModel: ProfileSettingsViewModel = .shared
    @Previewable @State var presented: Bool = true
    VStack {}
        .sheet(isPresented: $presented) {
            AssistantBuilderView(
                viewModel: viewModel,
                profileSettingsViewModel: profileSettingsViewModel
            )
        }
}
