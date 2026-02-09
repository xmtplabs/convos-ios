import SwiftUI

struct ConversationView<MessagesBottomBar: View>: View {
    @Bindable var viewModel: ConversationViewModel
    @Bindable var quicknameViewModel: QuicknameSettingsViewModel
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    let onScanInviteCode: () -> Void
    let onDeleteConversation: () -> Void
    let messagesTopBarTrailingItem: MessagesViewTopBarTrailingItem
    let messagesTopBarTrailingItemEnabled: Bool
    let messagesTextFieldEnabled: Bool
    @ViewBuilder let bottomBarContent: () -> MessagesBottomBar

    @State private var presentingShareView: Bool = false
    @State private var showingLockedInfo: Bool = false
    @State private var showingFullInfo: Bool = false
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
            displayName: $viewModel.myProfileViewModel.editingDisplayName,
            messageText: $viewModel.messageText,
            sendButtonEnabled: viewModel.sendButtonEnabled,
            profileImage: $viewModel.myProfileViewModel.profileImage,
            onboardingCoordinator: onboardingCoordinator,
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            messagesTextFieldEnabled: messagesTextFieldEnabled,
            onUserInteraction: {
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
            onTapInvite: viewModel.onTapInvite(_:),
            onReaction: viewModel.onReaction(emoji:messageId:),
            onTapReactions: viewModel.onTapReactions(_:),
            onDoubleTap: viewModel.onDoubleTap(_:),
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
                        onTapSetupQuickname: {
                            onboardingCoordinator.didTapProfilePhoto()
                            viewModel.onProfilePhotoTap(focusCoordinator: focusCoordinator)
                        },
                        onUseQuickname: viewModel.onUseQuickname(_:_:),
                        onPresentProfileSettings: viewModel.onProfileSettings
                    )
                }
                .padding(.horizontal, DesignConstants.Spacing.step4x)
            }
        )
        .animation(.easeOut, value: viewModel.explodeState)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .selfSizingSheet(isPresented: $viewModel.presentingConversationForked) {
            ConversationForkedInfoView {
                viewModel.leaveConvo()
            }
            .background(.colorBackgroundRaised)
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
                if viewModel.isLocked {
                    Button {
                        showingLockedInfo = true
                    } label: {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.colorTextSecondary)
                    }
                } else {
                    switch messagesTopBarTrailingItem {
                    case .share:
                        Button {
                            if viewModel.isFull {
                                showingFullInfo = true
                            } else {
                                presentingShareView = true
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(viewModel.isFull ? .colorTextSecondary : .colorTextPrimary)
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
                            Image(systemName: "viewfinder")
                        }
                        .buttonBorderShape(.circle)
                        .disabled(!messagesTopBarTrailingItemEnabled)
                    }
                }
            }
        }
        .sheet(item: $viewModel.presentingNewConversationForInvite) { viewModel in
            NewConversationView(
                viewModel: viewModel,
                quicknameViewModel: quicknameViewModel
            )
            .background(.colorBackgroundSurfaceless)
            .interactiveDismissDisabled(viewModel.conversationViewModel.onboardingCoordinator.isWaitingForInviteAcceptance)
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
        .selfSizingSheet(item: $viewModel.presentingReactionsForMessage) { message in
            ReactionsDrawerView(message: message) { reaction in
                viewModel.removeReaction(reaction, from: message)
            }
        }
        .selfSizingSheet(isPresented: $showingLockedInfo) {
            LockedConvoInfoView(
                isCurrentUserSuperAdmin: viewModel.isCurrentUserSuperAdmin,
                onUnlock: {
                    viewModel.toggleLock()
                    showingLockedInfo = false
                },
                onDismiss: {
                    showingLockedInfo = false
                }
            )
            .background(.colorBackgroundRaised)
        }
        .selfSizingSheet(isPresented: $showingFullInfo) {
            FullConvoInfoView(onDismiss: {
                showingFullInfo = false
            })
            .background(.colorBackgroundRaised)
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
            messagesTopBarTrailingItem: .share,
            messagesTopBarTrailingItemEnabled: true,
            messagesTextFieldEnabled: true,
            bottomBarContent: { EmptyView() }
        )
    }
}
