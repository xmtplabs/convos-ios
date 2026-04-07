import ConvosCore
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

    @State private var showingLockedInfo: Bool = false
    @State private var showingProcessingPowerInfo: Bool = false
    @State private var showingFullInfo: Bool = false
    @State private var showingAssistantsInfo: Bool = false
    @State private var scrollOverscrollAmount: CGFloat = 0.0
    @State private var didReleasePastThreshold: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction

    private var showPullToAddAssistant: Bool {
        !viewModel.conversation.hasAgent
            && !viewModel.isAssistantJoinPending
            && FeatureFlags.shared.isAssistantEnabled
            && GlobalConvoDefaults.shared.assistantsEnabled
    }

    private var messagesView: some View {
        @Bindable var onboardingCoordinator = viewModel.onboardingCoordinator
        return MessagesView(
            conversation: viewModel.conversation,
            messages: viewModel.messagesWithTypingIndicator,
            invite: viewModel.invite,
            hasLoadedAllMessages: viewModel.hasLoadedAllMessages,
            profile: viewModel.profile,
            untitledConversationPlaceholder: viewModel.untitledConversationPlaceholder,
            conversationNamePlaceholder: viewModel.conversationNamePlaceholder,
            conversationName: $viewModel.editingConversationName,
            conversationImage: $viewModel.conversationImage,
            displayName: $viewModel.myProfileViewModel.editingDisplayName,
            messageText: $viewModel.messageText,
            selectedAttachmentImage: $viewModel.selectedAttachmentImage,
            isVideoAttachment: viewModel.selectedVideoURL != nil,
            composerLinkPreview: viewModel.pastedLinkPreview,
            pendingInviteURL: viewModel.pendingInvite?.fullURL,
            pendingInviteExplodeDuration: viewModel.pendingInvite?.explodeDuration,
            onSetInviteExplodeDuration: { duration in viewModel.setInviteExplodeDuration(duration) },
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
            onClearInvite: viewModel.clearPendingInvite,
            onClearLinkPreview: { viewModel.pastedLinkPreview = nil },
            onTapAvatar: viewModel.onTapAvatar(_:),
            onTapInvite: viewModel.onTapInvite(_:),
            onReaction: viewModel.onReaction(emoji:messageId:),
            onToggleReaction: viewModel.onReaction(emoji:messageId:),
            onTapReactions: viewModel.onTapReactions(_:),
            onReply: { message in
                viewModel.onReply(message)
                focusCoordinator.moveFocus(to: .message)
            },
            replyingToMessage: viewModel.replyingToMessage,
            onCancelReply: viewModel.cancelReply,
            onDisplayNameEndedEditing: {
                viewModel.onDisplayNameEndedEditing(focusCoordinator: focusCoordinator, context: .quickEditor)
            },
            onProfileSettings: viewModel.onProfileSettings,
            onLoadPreviousMessages: viewModel.loadPreviousMessages,
            shouldBlurPhotos: viewModel.shouldBlurPhotos,
            onPhotoRevealed: viewModel.onPhotoRevealed(_:),
            onPhotoHidden: viewModel.onPhotoHidden(_:),
            onPhotoDimensionsLoaded: viewModel.onPhotoDimensionsLoaded(_:width:height:),
            onVideoSelected: viewModel.onVideoSelected(_:),
            onAboutAssistants: { showingAssistantsInfo = true },
            onAgentOutOfCredits: { showingProcessingPowerInfo = true },
            onTapUpdateMember: { viewModel.presentingProfileForMember = $0 },
            onRetryMessage: viewModel.retryMessage(_:),
            onDeleteMessage: viewModel.deleteMessage(_:),
            onRetryAssistantJoin: { viewModel.requestAssistantJoin() },
            onCopyInviteLink: { viewModel.copyInviteLink() },
            onConvoCode: {
                if viewModel.isFull {
                    showingFullInfo = true
                } else {
                    viewModel.presentingShareView = true
                }
            },
            onInviteAssistant: { viewModel.onRequestAssistantJoin() },
            onToggleTranscript: { messageId in
                viewModel.toggleTranscriptExpansion(for: messageId)
            },
            hasAssistant: viewModel.conversation.hasAgent,
            isAssistantJoinPending: viewModel.isAssistantJoinPending,
            isAssistantEnabled: FeatureFlags.shared.isAssistantEnabled && GlobalConvoDefaults.shared.assistantsEnabled,
            onBottomOverscrollChanged: { overscroll in
                scrollOverscrollAmount = overscroll
                if overscroll == 0 {
                    didReleasePastThreshold = false
                }
            },
            onBottomOverscrollReleased: { overscroll in
                if overscroll >= PullToAddAssistantView.activationThreshold,
                   !viewModel.isAssistantJoinPending {
                    didReleasePastThreshold = true
                }
            },
            onVoiceMemoTap: { viewModel.onVoiceMemoTapped() },
            voiceMemoRecorder: viewModel.voiceMemoRecorder,
            onSendVoiceMemo: { viewModel.sendVoiceMemo() },
            onConvosAction: { viewModel.onConvosButtonTapped() },
            bottomBarContent: {
                VStack(spacing: DesignConstants.Spacing.step3x) {
                    if showPullToAddAssistant {
                        PullToAddAssistantView(
                            overscrollAmount: scrollOverscrollAmount,
                            didReleasePastThreshold: didReleasePastThreshold,
                            onTriggered: {
                                viewModel.onRequestAssistantJoin()
                            }
                        )
                        .fixedSize()
                        .frame(height: 0, alignment: .bottom)
                        .allowsHitTesting(false)
                    }

                    bottomBarContent()

                    ConversationOnboardingView(
                        coordinator: onboardingCoordinator,
                        focusCoordinator: focusCoordinator,
                        scrollOverscrollAmount: scrollOverscrollAmount,
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
    }

    var body: some View {
        messagesView
        .onChange(of: viewModel.selectedAttachmentImage) { oldValue, newValue in
            if let image = newValue {
                viewModel.onPhotoSelected(image)
            } else if oldValue != nil {
                viewModel.onPhotoRemoved()
            }
        }
        .onChange(of: viewModel.messageText) { _, _ in
            viewModel.checkForInviteURL()
            viewModel.checkForPastedLink()
        }
        .animation(.easeOut, value: viewModel.explodeState)
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
                if viewModel.isLocked {
                    Button {
                        showingLockedInfo = true
                    } label: {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.colorTextSecondary)
                    }
                    .accessibilityLabel("Conversation locked")
                    .accessibilityHint("Tap for lock details")
                    .accessibilityIdentifier("lock-info-button")
                } else {
                    switch messagesTopBarTrailingItem {
                    case .share:
                        AddToConversationMenu(
                            isFull: viewModel.isFull,
                            hasAssistant: viewModel.conversation.hasAgent,
                            isAssistantJoinPending: viewModel.isAssistantJoinPending,
                            isEnabled: messagesTopBarTrailingItemEnabled,
                            onConvoCode: {
                                if viewModel.isFull {
                                    showingFullInfo = true
                                } else {
                                    viewModel.presentingShareView = true
                                }
                            },
                            onCopyLink: {
                                viewModel.copyInviteLink()
                            },
                            onInviteAssistant: {
                                viewModel.onRequestAssistantJoin()
                            }
                        )
                    case .scan:
                        Button {
                            onScanInviteCode()
                        } label: {
                            Image(systemName: "viewfinder")
                        }
                        .buttonBorderShape(.circle)
                        .disabled(!messagesTopBarTrailingItemEnabled)
                        .accessibilityLabel("Scan invite code")
                        .accessibilityIdentifier("scan-invite-button")
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
        }
        .selfSizingSheet(isPresented: $viewModel.presentingAssistantConfirmation) {
            AssistantsInfoView(
                isConfirmation: true,
                onConfirm: { viewModel.requestAssistantJoin() }
            )
            .padding(.top, 20)
        }
        .selfSizingSheet(isPresented: $showingProcessingPowerInfo) {
            AssistantProcessingPowerInfoView()
                .padding(.top, 20)
        }
        .selfSizingSheet(isPresented: $showingAssistantsInfo) {
            AssistantsInfoView()
                .padding(.top, 20)
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
                isLocked: viewModel.isLocked,
                onLock: {
                    viewModel.toggleLock()
                    showingLockedInfo = false
                },
                onDismiss: {
                    showingLockedInfo = false
                }
            )
        }
        .selfSizingSheet(isPresented: $showingFullInfo) {
            FullConvoInfoView(onDismiss: {
                showingFullInfo = false
            })
        }
        .selfSizingSheet(
            isPresented: $viewModel.presentingRevealMediaInfoSheet,
            onDismiss: { viewModel.showRevealSettingsToast() },
            content: {
                RevealMediaInfoSheet()
            }
        )
        .selfSizingSheet(
            isPresented: $viewModel.presentingPhotosInfoSheet,
            onDismiss: { focusCoordinator.moveFocus(to: .message) },
            content: {
                PhotosInfoSheet()
            }
        )
        .onDisappear {
            VoiceMemoPlayer.shared.stop()
            viewModel.voiceMemoRecorder.cancelRecording()
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
