import SwiftUI

struct ConversationView<MessagesBottomBar: View>: View {
    @Bindable var viewModel: ConversationViewModel
    @Bindable var quicknameViewModel: QuicknameSettingsViewModel
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    let onScanInviteCode: () -> Void
    let onDeleteConversation: () -> Void
    let confirmDeletionBeforeDismissal: Bool
    let messagesTopBarTrailingItem: MessagesViewTopBarTrailingItem
    let messagesTopBarTrailingItemEnabled: Bool
    let messagesTextFieldEnabled: Bool
    @ViewBuilder let bottomBarContent: () -> MessagesBottomBar

    @State private var presentingShareView: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        @Bindable var onboardingCoordinator = viewModel.onboardingCoordinator
        MessagesView(
            conversation: viewModel.conversation,
            messages: viewModel.messages,
            invite: viewModel.invite,
            hasLoadedAllMessages: viewModel.hasLoadedAllMessages,
            profile: viewModel.profile,
            untitledConversationPlaceholder: viewModel.untitledConversationPlaceholder,
            conversationNamePlaceholder: viewModel.conversationNamePlaceholder,
            conversationName: $viewModel.editingConversationName,
            conversationImage: $viewModel.conversationImage,
            displayName: $viewModel.editingDisplayName,
            messageText: $viewModel.messageText,
            sendButtonEnabled: $viewModel.sendButtonEnabled,
            profileImage: $viewModel.profileImage,
            onboardingCoordinator: onboardingCoordinator,
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            messagesTextFieldEnabled: messagesTextFieldEnabled,
            scrollViewWillBeginDragging: {
                viewModel.dismissQuickEditor()
                focusCoordinator.dismissQuickEditor()
            },
            onProfilePhotoTap: {
                onboardingCoordinator.didTapProfilePhoto()
                viewModel.onProfilePhotoTap(focusCoordinator: focusCoordinator)
            },
            onSendMessage: {
                viewModel.onSendMessage(focusCoordinator: focusCoordinator)
            },
            onTapAvatar: viewModel.onTapAvatar(_:),
            onDisplayNameEndedEditing: {
                viewModel.onDisplayNameEndedEditing(focusCoordinator: focusCoordinator, context: .quickEditor)
            },
            onProfileSettings: viewModel.onProfileSettings,
            onLoadPreviousMessages: viewModel.loadPreviousMessages,
            bottomBarContent: {
                VStack(spacing: DesignConstants.Spacing.step3x) {
                    bottomBarContent()

                    ConversationOnboardingView(
                        coordinator: onboardingCoordinator,
                        focusCoordinator: focusCoordinator,
                        onUseQuickname: viewModel.onUseQuickname(_:_:),
                        onPresentProfileSettings: viewModel.onProfileSettings
                    )
                }
                .padding(.horizontal, DesignConstants.Spacing.step4x)
            }
        )
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .selfSizingSheet(isPresented: $viewModel.presentingConversationForked) {
            ConversationForkedInfoView {
                viewModel.leaveConvo()
            }
        }
        .sheet(isPresented: $viewModel.presentingProfileSettings) {
            MyInfoView(
                profile: .constant(viewModel.myProfileViewModel.profile),
                profileImage: $viewModel.myProfileViewModel.profileImage,
                editingDisplayName: $viewModel.myProfileViewModel.editingDisplayName,
                quicknameViewModel: quicknameViewModel,
                showsCancelButton: true,
                showsProfile: true,
                showsUseQuicknameButton: true,
                canEditQuickname: false
            ) { quicknameSettings in
                viewModel.onUseQuickname(quicknameSettings.profile, quicknameSettings.profileImage)
            }
            .onDisappear {
                viewModel.onProfileSettingsDismissed(focusCoordinator: focusCoordinator)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                switch messagesTopBarTrailingItem {
                case .share:
                    Button {
                        presentingShareView = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.colorTextPrimary)
                    }
                    .fullScreenCover(isPresented: $presentingShareView) {
                        ConversationShareView(conversation: viewModel.conversation, invite: viewModel.invite)
                            .presentationBackground(.clear)
                    }
                    .disabled(!messagesTopBarTrailingItemEnabled)
                    .transaction { transaction in
                        transaction.disablesAnimations = true
                    }
                case .scan:
                    Button {
                        onScanInviteCode()
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .buttonBorderShape(.circle)
                    .disabled(!messagesTopBarTrailingItemEnabled)
                }
            }
        }
        .sheet(item: $viewModel.presentingProfileForMember) { member in
            NavigationStack {
                ConversationMemberView(viewModel: viewModel, member: member)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(role: .cancel) {
                                viewModel.presentingProfileForMember = nil
                            }
                        }
                    }
            }
        }
    }
}

#Preview {
    @Previewable @State var viewModel: ConversationViewModel = .mock
    @Previewable @State var quicknameViewModel: QuicknameSettingsViewModel = .shared
    @Previewable @FocusState var focusState: MessagesViewInputFocus?
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    NavigationStack {
        ConversationView(
            viewModel: viewModel,
            quicknameViewModel: quicknameViewModel,
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            onScanInviteCode: {},
            onDeleteConversation: {},
            confirmDeletionBeforeDismissal: true,
            messagesTopBarTrailingItem: .share,
            messagesTopBarTrailingItemEnabled: true,
            messagesTextFieldEnabled: true,
            bottomBarContent: { EmptyView() }
        )
    }
}
