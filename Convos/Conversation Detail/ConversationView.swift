import ConvosCore
import ConvosCoreiOS
import ConvosMetrics
import SwiftUI

struct ConversationView<MessagesBottomBar: View>: View {
    @Bindable var viewModel: ConversationViewModel
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    let onScanInviteCode: () -> Void
    let onDeleteConversation: () -> Void
    let messagesTopBarTrailingItem: MessagesViewTopBarTrailingItem
    let messagesTopBarTrailingItemEnabled: Bool
    let messagesTextFieldEnabled: Bool
    @ViewBuilder let bottomBarContent: () -> MessagesBottomBar

    @State private var scrollOverscrollAmount: CGFloat = 0.0
    @State private var didReleasePastThreshold: Bool = false
    @State private var pagerSelectedPage: ConversationPagerPage = .messages
    @State private var isKeyboardVisible: Bool = false
    @State private var showingDebugInjector: Bool = false
    @State private var presentingAddFromContactsPicker: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction

    /// Substitutes the user's contact (name + avatar) for any member's
    /// per-conversation profile when the inbox is a known contact. The
    /// chat surfaces this so the join-system row reads
    /// "Alice joined" with Alice's avatar instead of "Somebody" + S
    /// monogram while Alice has not yet published her per-conversation
    /// profile. Built once per `ConversationView` lifetime; reads
    /// through the messaging service's contacts repository.
    private var contactOverride: @Sendable (String) -> Contact? {
        viewModel.messagingService.contactsRepository().contact(for:)
    }

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
            pendingMediaAttachments: viewModel.pendingMediaAttachments,
            composerLinkPreview: viewModel.pastedLinkPreview,
            pendingInviteURL: viewModel.pendingInvite?.fullURL,
            pendingInviteEmoji: viewModel.conversation.conversationEmoji,
            pendingInviteConvoName: $viewModel.pendingInviteConvoName,
            pendingInviteImage: $viewModel.pendingInviteImage,
            pendingInviteExplodeDuration: viewModel.pendingInvite?.explodeDuration,
            onSetInviteExplodeDuration: { duration in viewModel.setInviteExplodeDuration(duration) },
            onInviteConvoNameEditingEnded: { name in
                viewModel.updateLinkedConversationName(name)
                focusCoordinator.endEditing(for: .sideConvoName, context: .quickEditor)
            },
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
            onClearMediaAttachment: viewModel.removeMediaAttachment(id:),
            onTapAvatar: viewModel.onTapAvatar(_:),
            onTapInvite: viewModel.onTapInvite(_:),
            onReaction: viewModel.onReaction(emoji:messageId:),
            onToggleReaction: viewModel.onReaction(emoji:messageId:),
            onTapReactions: viewModel.onTapReactions(_:),
            onTapReadReceipts: viewModel.onTapReadReceipts(_:),
            onReply: { message in
                viewModel.onReply(message)
                focusCoordinator.moveFocus(to: .message)
            },
            replyingToMessage: viewModel.replyingToMessage,
            replyingToAudioTranscriptText: viewModel.replyingToAudioTranscriptText,
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
            onPhotoSelected: viewModel.addPhotoAttachment(_:),
            onVideoSelected: viewModel.addVideoAttachment(url:),
            onFileSelected: viewModel.addFileAttachment(url:filename:mimeType:fileSize:),
            onAboutAssistants: { viewModel.navigator.present(assistantInfo: AssistantInfoNavigatorArgs()) },
            onAgentOutOfCredits: { viewModel.navigator.present(processingPowerInfo: ProcessingPowerInfoNavigatorArgs()) },
            onTapUpdateMember: { member in
                viewModel.navigator.present(memberProfile: MemberProfileNavigatorArgs(
                    conversationId: viewModel.conversation.id,
                    memberId: member.profile.inboxId
                ))
                viewModel.presentingProfileForMember = member
            },
            onRetryMessage: viewModel.retryMessage(_:),
            onDeleteMessage: viewModel.deleteMessage(_:),
            onRetryAssistantJoin: { viewModel.requestAssistantJoin() },
            onCopyInviteLink: { viewModel.copyInviteLink() },
            onConvoCode: {
                if viewModel.isFull {
                    viewModel.navigator.present(fullConvoInfo: FullConvoInfoNavigatorArgs())
                } else {
                    viewModel.navigator.present(shareInvite: ShareInviteNavigatorArgs(conversationId: viewModel.conversation.id))
                }
            },
            onInviteAssistant: { viewModel.onRequestAssistantJoin() },
            onRetryTranscript: { item in
                viewModel.retryTranscript(for: item)
            },
            profileSheetForMember: profileSheetForMember,
            memberContactOverride: contactOverride,
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
            onDebugAttachmentTap: debugAttachmentTapHandler,
            extraBottomInset: pagerDotsInset,
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

                    Group {
                        if viewModel.showsCapabilityApprovedToast {
                            CapabilityApprovedToastView()
                                .transition(.blurReplace)
                        } else if let layout = viewModel.pendingCapabilityPickerLayout {
                            CapabilityPickerCardView(
                                layout: layout,
                                assistantName: viewModel.askerDisplayName(for: layout.request),
                                onApprove: { providerIds in
                                    viewModel.onCapabilityApprove(providerIds: providerIds)
                                },
                                onDeny: {
                                    viewModel.onCapabilityDeny()
                                },
                                onConnect: { providerId in
                                    viewModel.onCapabilityConnect(providerId: providerId)
                                }
                            )
                            .transition(.blurReplace)
                        } else {
                            ConversationOnboardingView(
                                coordinator: onboardingCoordinator,
                                focusCoordinator: focusCoordinator,
                                scrollOverscrollAmount: scrollOverscrollAmount,
                                onTapSetupProfile: {
                                    onboardingCoordinator.didTapProfilePhoto()
                                    viewModel.onProfilePhotoTap(focusCoordinator: focusCoordinator)
                                },
                                onUseProfile: viewModel.onUseProfile(_:_:),
                                onPresentProfileSettings: viewModel.onProfileSettings,
                                setupProfileNavState: viewModel.setupProfileNavState,
                                setupProfileNavigator: viewModel.setupProfileNavigator,
                                inviteAcceptedNavState: viewModel.inviteAcceptedNavState,
                                inviteAcceptedNavigator: viewModel.inviteAcceptedNavigator,
                                requestPushNotificationsNavState: viewModel.requestPushNotificationsNavState,
                                requestPushNotificationsNavigator: viewModel.requestPushNotificationsNavigator,
                                onAppearSetupProfile: {
                                    viewModel.navigator.present(setupProfile: SetupProfileNavigatorArgs())
                                },
                                onAppearInviteAccepted: {
                                    viewModel.navigator.present(inviteAccepted: InviteAcceptedNavigatorArgs())
                                },
                                onAppearRequestPushNotifications: {
                                    viewModel.navigator.present(requestPushNotifications: RequestPushNotificationsNavigatorArgs())
                                }
                            )
                            .transition(.blurReplace)
                        }
                    }
                    .animation(.spring(duration: 0.4, bounce: 0.2), value: viewModel.pendingCapabilityPickerLayout)
                    .animation(.spring(duration: 0.4, bounce: 0.2), value: viewModel.showsCapabilityApprovedToast)
                }
                .padding(.horizontal, DesignConstants.Spacing.step4x)
            }
        )
    }

    @ToolbarContentBuilder
    private var topBarTrailing: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if viewModel.isLocked {
                lockedInfoButton
            } else {
                switch messagesTopBarTrailingItem {
                case .share: addToConversationMenu
                case .scan: scanInviteButton
                }
            }
        }
    }

    private var lockedInfoButton: some View {
        Button {
            viewModel.navigator.present(lockedConvoInfo: LockedConvoInfoNavigatorArgs(conversationId: viewModel.conversation.id))
        } label: {
            Image(systemName: "lock.fill")
                .foregroundStyle(.colorTextSecondary)
        }
        .accessibilityLabel("Conversation locked")
        .accessibilityHint("Tap for lock details")
        .accessibilityIdentifier("lock-info-button")
    }

    private var addToConversationMenu: some View {
        AddToConversationMenu(
            isFull: viewModel.isFull,
            hasAssistant: viewModel.conversation.hasAgent,
            isAssistantJoinPending: viewModel.isAssistantJoinPending,
            isEnabled: messagesTopBarTrailingItemEnabled,
            onConvoCode: {
                if viewModel.isFull {
                    viewModel.navigator.present(fullConvoInfo: FullConvoInfoNavigatorArgs())
                } else {
                    viewModel.navigator.present(shareInvite: ShareInviteNavigatorArgs(conversationId: viewModel.conversation.id))
                }
            },
            onCopyLink: {
                viewModel.copyInviteLink()
            },
            onInviteAssistant: {
                viewModel.onRequestAssistantJoin()
            },
            onAddFromContacts: handleAddFromContactsTap
        )
    }

    private var handleAddFromContactsTap: () -> Void {
        { presentingAddFromContactsPicker = true }
    }

    @ViewBuilder
    private func memberContactDetailSheet(for member: ConversationMember) -> some View {
        MemberContactDetailSheetContent(viewModel: viewModel, member: member, profileSettingsViewModel: profileSettingsViewModel)
    }

    private var scanInviteButton: some View {
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

    private var debugAttachmentTapHandler: (() -> Void)? {
        guard FeatureFlags.shared.isDebugInjectorEnabled else { return nil }
        return { showingDebugInjector = true }
    }

    private var debugInjectorBinding: Binding<Bool> {
        guard FeatureFlags.shared.isDebugInjectorEnabled else { return .constant(false) }
        return $showingDebugInjector
    }

    private var stuffPage: some View {
        AssistantFilesLinksView(
            conversationId: viewModel.conversation.id,
            repository: viewModel.makeAssistantFilesLinksRepository(),
            members: viewModel.conversation.members,
            usesInlineHeader: true,
            profileSheetContent: profileSheetForMember,
            focusBinding: $focusState
        )
    }

    private func profileSheetForMember(_ member: ConversationMember) -> AnyView {
        AnyView(MemberContactDetailSheetContent(viewModel: viewModel, member: member, profileSettingsViewModel: profileSettingsViewModel))
    }

    private var pagerDotsInset: CGFloat {
        isKeyboardVisible ? 0.0 : 24.0
    }

    @ViewBuilder
    private var messagesPageContent: some View {
        VStack(spacing: 0) {
            LowBalanceBanner()
            messagesView
        }
    }

    var body: some View {
        ConversationPager(
            selectedPage: $pagerSelectedPage,
            showsPageDots: !isKeyboardVisible,
            messagesPage: { messagesPageContent },
            stuffPage: { stuffPage }
        )
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onChange(of: pagerSelectedPage) { _, newPage in
            if newPage != .stuff {
                focusCoordinator.dismissStuffSearchIfNeeded()
            }
        }
        .onChange(of: viewModel.messageText) { _, _ in
            viewModel.checkForInviteURL()
            viewModel.checkForPastedLink()
        }
        .animation(.easeOut, value: viewModel.explodeState)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onAppear {
            viewModel.onConversationAppeared()
            viewModel.navState.markScreenAppeared()
        }
        .task {
            await CreditsServices.shared.refresh()
        }
        .onDisappear {
            focusCoordinator.dismissStuffSearchIfNeeded()
            viewModel.onConversationDisappeared()
            let durationSecs = viewModel.navState.screenAppearAt.map { Float(Date().timeIntervalSince($0)) } ?? 0
            viewModel.navigator.closed(context: ScreenContext(durationSecs: durationSecs))
        }
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
                profileSettingsViewModel: profileSettingsViewModel,
                showsCancelButton: true,
                showsProfile: true,
                showsUseProfileButton: true,
                canEditProfile: false
            ) { profileSettings in
                viewModel.onUseProfile(profileSettings.profile, profileSettings.profileImage)
            }
            .onDisappear {
                viewModel.onProfileSettingsDismissed(focusCoordinator: focusCoordinator)
            }
        }
        .toolbar { topBarTrailing }
        .debugConnectionInjectorSheet(
            isPresented: debugInjectorBinding,
            conversationId: viewModel.conversation.id,
            messagingService: viewModel.messagingService
        )
        .onReceive(NotificationCenter.default.publisher(for: .requestAddFromContactsInCurrentConversation)) { _ in
            // Surfaces from `NewConvoIdentityView`'s invite-members menu in
            // the new-conversation flow. Reuses the same picker state the
            // chat plus-menu's "Add from Contacts" row drives.
            presentingAddFromContactsPicker = true
        }
        .addFromContactsPicker(
            viewModel: viewModel,
            isPresented: $presentingAddFromContactsPicker
        )
        .sheet(item: $viewModel.presentingNewConversationForInvite) { viewModel in
            NewConversationView(
                viewModel: viewModel,
                profileSettingsViewModel: profileSettingsViewModel
            )
            .background(.colorBackgroundSurfaceless)
        }
        .selfSizingSheet(isPresented: $viewModel.presentingExplodedInviteInfo) {
            ExplodeInfoView()
        }
        .selfSizingSheet(isPresented: $viewModel.presentingAssistantConfirmation) {
            AssistantsInfoView(
                isConfirmation: true,
                onConfirm: { viewModel.requestAssistantJoin() }
            )
            .padding(.top, 20)
        }
        .selfSizingSheet(isPresented: $viewModel.navState.presentingProcessingPowerInfo) {
            AssistantProcessingPowerInfoView()
                .padding(.top, 20)
        }
        .selfSizingSheet(isPresented: $viewModel.navState.presentingAssistantInfo) {
            AssistantsInfoView()
                .padding(.top, 20)
        }
        .sheet(item: $viewModel.presentingProfileForMember) { member in
            memberContactDetailSheet(for: member)
        }
        .selfSizingSheet(item: $viewModel.presentingReactionsForMessage) { message in
            ReactionsDrawerView(message: message) { reaction in
                viewModel.removeReaction(reaction, from: message)
            }
        }
        .selfSizingSheet(item: $viewModel.presentingReadByForGroup) { group in
            ReadByDrawerView(members: group.readByMembers)
        }
        .selfSizingSheet(isPresented: $viewModel.navState.presentingLockedConvoInfo) {
            LockedConvoInfoView(
                isCurrentUserSuperAdmin: viewModel.isCurrentUserSuperAdmin,
                isLocked: viewModel.isLocked,
                onLock: {
                    viewModel.toggleLock()
                    viewModel.navState.presentingLockedConvoInfo = false
                },
                onDismiss: {
                    viewModel.navState.presentingLockedConvoInfo = false
                }
            )
            .onAppear { viewModel.lockedConvoInfoNavState.markScreenAppeared() }
            .onDisappear {
                let durationSecs: Float = viewModel.lockedConvoInfoNavState.screenAppearAt
                    .map { Float(Date().timeIntervalSince($0)) } ?? 0
                viewModel.lockedConvoInfoNavigator.closed(context: ScreenContext(durationSecs: durationSecs))
            }
        }
        .selfSizingSheet(isPresented: $viewModel.navState.presentingFullConvoInfo) {
            FullConvoInfoView(onDismiss: {
                viewModel.navState.presentingFullConvoInfo = false
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
        .selfSizingSheet(isPresented: $viewModel.navState.presentingBackwardsSecrecyInfo) {
            BackwardsSecrecyInfoView()
                .onAppear { viewModel.backwardsSecrecyInfoNavState.markScreenAppeared() }
                .onDisappear {
                    let durationSecs: Float = viewModel.backwardsSecrecyInfoNavState.screenAppearAt
                        .map { Float(Date().timeIntervalSince($0)) } ?? 0
                    viewModel.backwardsSecrecyInfoNavigator.closed(context: ScreenContext(durationSecs: durationSecs))
                }
        }
        .onDisappear {
            VoiceMemoPlayer.shared.stop()
            viewModel.voiceMemoRecorder.cancelRecording()
        }
    }
}

@MainActor
private func makeConversationViewPreviewViewModel() -> ConversationViewModel {
    .mock
}

struct MemberContactDetailSheetContent: View {
    let viewModel: ConversationViewModel
    let member: ConversationMember
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        let messagingService = viewModel.messagingService
        let contactsRepository = messagingService.contactsRepository()
        let contactsWriter = messagingService.contactsWriter()
        let resolvedContact = Contact.resolved(
            member: member,
            in: viewModel.conversation.id,
            contactsRepository: contactsRepository
        )
        let onRemove: () -> Void = {
            viewModel.remove(member: member)
            dismiss()
        }
        NavigationStack {
            ContactDetailView(
                contact: resolvedContact,
                mode: .scopedToConversation(
                    conversationId: viewModel.conversation.id,
                    canRemoveMembers: viewModel.canRemoveMembers,
                    isCurrentUser: member.isCurrentUser,
                    invitedBy: member.invitedBy,
                    joinedAt: member.joinedAt
                ),
                contactsWriter: contactsWriter,
                contactsRepository: contactsRepository,
                session: viewModel.session,
                profileSettingsViewModel: profileSettingsViewModel,
                onRemove: onRemove
            )
        }
    }
}

#Preview {
    @Previewable @State var viewModel: ConversationViewModel = makeConversationViewPreviewViewModel()
    @Previewable @State var profileSettingsViewModel: ProfileSettingsViewModel = .shared
    @Previewable @FocusState var focusState: MessagesViewInputFocus?
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    NavigationStack {
        ConversationView(
            viewModel: viewModel,
            profileSettingsViewModel: profileSettingsViewModel,
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
