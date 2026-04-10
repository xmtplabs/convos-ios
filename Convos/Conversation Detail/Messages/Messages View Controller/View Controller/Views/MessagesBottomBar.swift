import ConvosCore
import ConvosCoreiOS
import PhotosUI
import SwiftUI

enum MessagesViewInputFocus: Hashable {
    case message, displayName, conversationName, voiceMemoRecording
}

struct MessagesBottomBar<BottomBarContent: View>: View {
    let profile: Profile
    @Binding var displayName: String
    let emptyDisplayNamePlaceholder: String = "Somebody"
    @Binding var messageText: String
    @Binding var selectedAttachmentImage: UIImage?
    var isVideoAttachment: Bool = false
    var composerLinkPreview: LinkPreview?
    var pendingInviteURL: String?
    var pendingInviteEmoji: String?
    var pendingInviteExplodeDuration: ExplodeDuration?
    var onSetInviteExplodeDuration: ((ExplodeDuration?) -> Void)?
    let sendButtonEnabled: Bool
    @Binding var profileImage: UIImage?
    @Binding var isPhotoPickerPresented: Bool
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    let onboardingCoordinator: ConversationOnboardingCoordinator
    let messagesTextFieldEnabled: Bool
    let onProfilePhotoTap: () -> Void
    let onSendMessage: () -> Void
    let onClearInvite: () -> Void
    let onClearLinkPreview: () -> Void
    let onDisplayNameEndedEditing: () -> Void
    let onVideoSelected: (URL) -> Void
    let onProfileSettings: () -> Void
    let onVoiceMemoTap: () -> Void
    @Bindable var voiceMemoRecorder: VoiceMemoRecorder
    let onSendVoiceMemo: () -> Void
    let onConvosAction: () -> Void
    let onBaseHeightChanged: (CGFloat) -> Void
    @ViewBuilder let bottomBarContent: () -> BottomBarContent

    @State private var quicknameSettings: QuicknameSettingsViewModel = .shared

    @State private var voiceMemoKeyboardKeeperText: String = ""
    @State private var isExpanded: Bool = false
    @State private var isMessageInputFocused: Bool = false
    @State private var isImagePickerPresented: Bool = false
    @State private var isCameraPresented: Bool = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var previousFocus: MessagesViewInputFocus?
    @State private var voiceMemoReturnFocus: MessagesViewInputFocus?
    @State private var didSelectPhotoThisSession: Bool = false
    @Namespace private var namespace: Namespace.ID

    var quicknamePlaceholderText: String {
        onboardingCoordinator.state == .settingUpQuickname ? "Add your name" : "Your name"
    }

    var body: some View {
        VStack(spacing: 0) {
            bottomBarContent()
            VoiceMemoKeyboardFocusKeeper(
                focusState: $focusState,
                text: $voiceMemoKeyboardKeeperText
            )
            GlassEffectContainer {
                ZStack {
                    if !isExpanded {
                        collapsedInputView
                    }

                    if isExpanded {
                        expandedQuickEditView
                    }
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.top, DesignConstants.Spacing.step2x)
            .padding(.bottom, DesignConstants.Spacing.step4x)
        }
        .background(HeightReader())
        .onPreferenceChange(HeightPreferenceKey.self) { height in
            onBaseHeightChanged(height)
        }
        .onChange(of: focusCoordinator.currentFocus) { _, newValue in
            guard !isImagePickerPresented else { return }

            withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
                isExpanded = newValue == .displayName
                isMessageInputFocused = newValue == .message || newValue == .voiceMemoRecording
            }
        }
        .onChange(of: messageText) { _, _ in
            guard !isMessageInputFocused, focusCoordinator.currentFocus != .displayName else { return }
            withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
                isMessageInputFocused = true
            }
        }
        .onChange(of: isVoiceMemoActive) { wasActive, isActive in
            guard wasActive, !isActive else { return }
            restoreVoiceMemoFocusIfNeeded()
        }
        .onChange(of: isPhotoPickerPresented) { _, newValue in
            if newValue {
                previousFocus = focusCoordinator.currentFocus
                didSelectPhotoThisSession = false
                focusState = nil
            } else {
                if !didSelectPhotoThisSession, let previousFocus {
                    focusCoordinator.moveFocus(to: previousFocus)
                }
            }
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $selectedPhoto, matching: .any(of: [.images, .videos]))
        .onChange(of: selectedPhoto) { _, newValue in
            Task {
                guard let newValue else { return }

                if let videoFile = try? await newValue.loadTransferable(type: VideoFile.self) {
                    onVideoSelected(videoFile.url)
                    selectedPhoto = nil
                    didSelectPhotoThisSession = true
                    isPhotoPickerPresented = false
                    focusCoordinator.moveFocus(to: .message)
                } else if let data = try? await newValue.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) {
                    selectedAttachmentImage = image
                    selectedPhoto = nil
                    didSelectPhotoThisSession = true
                    isPhotoPickerPresented = false
                    focusCoordinator.moveFocus(to: .message)
                }
            }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPickerView(
                onImageCaptured: { image in
                    selectedAttachmentImage = image
                    isCameraPresented = false
                    focusCoordinator.moveFocus(to: .message)
                },
                onVideoCaptured: { url in
                    onVideoSelected(url)
                    isCameraPresented = false
                    focusCoordinator.moveFocus(to: .message)
                }
            )
            .ignoresSafeArea()
        }
    }

    private var isVoiceMemoActive: Bool {
        switch voiceMemoRecorder.state {
        case .recording, .recorded: return true
        case .idle: return false
        }
    }

    private func startVoiceMemoRecording() {
        if let currentFocus = focusCoordinator.currentFocus {
            voiceMemoReturnFocus = currentFocus
            focusCoordinator.moveFocus(to: .voiceMemoRecording)
        } else {
            voiceMemoReturnFocus = nil
        }
        onVoiceMemoTap()
    }

    private func restoreVoiceMemoFocusIfNeeded() {
        guard focusCoordinator.currentFocus == .voiceMemoRecording,
              let voiceMemoReturnFocus else {
            self.voiceMemoReturnFocus = nil
            return
        }

        focusCoordinator.moveFocus(to: voiceMemoReturnFocus)
        self.voiceMemoReturnFocus = nil
    }

    @ViewBuilder
    private var collapsedInputView: some View {
        if case .recording = voiceMemoRecorder.state {
            VoiceMemoRecordingView(recorder: voiceMemoRecorder)
                .frame(minHeight: 52)
                .clipShape(.capsule)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("media", in: namespace)
                .glassEffectTransition(.matchedGeometry)
        } else if case .recorded(let url, let duration) = voiceMemoRecorder.state {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Button {
                    withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
                        voiceMemoRecorder.cancelRecording()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.colorTextSecondary)
                        .frame(width: DesignConstants.Spacing.step12x, height: DesignConstants.Spacing.step12x)
                }
                .clipShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Discard voice memo")
                .accessibilityIdentifier("voice-memo-cancel-button")

                VoiceMemoReviewView(
                    audioURL: url,
                    duration: duration,
                    levels: voiceMemoRecorder.audioLevels,
                    onSend: { onSendVoiceMemo() }
                )
                .frame(minHeight: 52)
                .clipShape(.capsule)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("media", in: namespace)
                .glassEffectTransition(.matchedGeometry)
            }
        } else {
            normalInputView
        }
    }

    @ViewBuilder
    private var normalInputView: some View {
        HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step2x) {
            if isMessageInputFocused {
                Button {
                    withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
                        isMessageInputFocused = false
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18.0, weight: .medium))
                        .foregroundStyle(Color.colorTextTertiary)
                        .frame(width: 32, height: 32)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show media buttons")
                .accessibilityIdentifier("collapse-input-button")
                .opacity(messagesTextFieldEnabled ? 1.0 : 0.4)
                .frame(width: DesignConstants.Spacing.step12x, height: DesignConstants.Spacing.step12x)
                .clipShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("media", in: namespace)
                .glassEffectTransition(.matchedGeometry)
            } else {
                MessagesMediaButtonsView(
                    isPhotoPickerPresented: $isPhotoPickerPresented,
                    isCameraPresented: $isCameraPresented,
                    onVoiceMemoTap: startVoiceMemoRecording,
                    onConvosAction: {
                        withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
                            isMessageInputFocused = true
                        }
                        onConvosAction()
                    }
                )
                .opacity(messagesTextFieldEnabled ? 1.0 : 0.4)
                .frame(height: DesignConstants.Spacing.step12x)
                .clipShape(.capsule)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("media", in: namespace)
                .glassEffectTransition(.matchedGeometry)
            }

            MessagesInputView(
                profile: profile,
                profileImage: $profileImage,
                displayName: $displayName,
                emptyDisplayNamePlaceholder: emptyDisplayNamePlaceholder,
                messageText: $messageText,
                selectedAttachmentImage: $selectedAttachmentImage,
                isVideoAttachment: isVideoAttachment,
                composerLinkPreview: composerLinkPreview,
                pendingInviteURL: pendingInviteURL,
                pendingInviteEmoji: pendingInviteEmoji,
                pendingInviteExplodeDuration: pendingInviteExplodeDuration,
                onSetInviteExplodeDuration: onSetInviteExplodeDuration,
                sendButtonEnabled: sendButtonEnabled,
                focusState: $focusState,
                animateAvatarForQuickname: onboardingCoordinator.shouldAnimateAvatarForQuicknameSetup,
                messagesTextFieldEnabled: messagesTextFieldEnabled,
                isCollapsed: !isMessageInputFocused,
                onProfilePhotoTap: onProfilePhotoTap,
                onSendMessage: onSendMessage,
                onClearInvite: onClearInvite,
                onClearLinkPreview: onClearLinkPreview
            )
            .opacity(messagesTextFieldEnabled ? 1.0 : 0.4)
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(.rect(cornerRadius: 26.0))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26.0))
            .glassEffectID("input", in: namespace)
            .glassEffectTransition(.matchedGeometry)
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard !isMessageInputFocused else { return }
                    withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
                        isMessageInputFocused = true
                    }
                }
            )
        }
        .disabled(!messagesTextFieldEnabled)
    }

    @ViewBuilder
    private var expandedQuickEditView: some View {
        QuickEditView(
            placeholderText: quicknamePlaceholderText,
            text: $displayName,
            image: $profileImage,
            isImagePickerPresented: $isImagePickerPresented,
            focusState: $focusState,
            focused: .displayName,
            settingsSymbolName: "lanyardcard.fill",
            showsSettingsButton: !quicknameSettings.quicknameSettings.isDefault && !onboardingCoordinator.isSettingUpQuickname,
            onSubmit: onDisplayNameEndedEditing,
            onSettings: onProfileSettings
        )
        .frame(maxWidth: 320.0)
        .padding(DesignConstants.Spacing.step6x)
        .clipShape(.rect(cornerRadius: 40.0))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 40.0))
        .glassEffectID("profileEditor", in: namespace)
        .glassEffectTransition(.matchedGeometry)
    }
}

#Preview {
    @Previewable @State var profile: Profile = .mock()
    @Previewable @State var profileName: String = ""
    @Previewable @State var messageText: String = ""
    @Previewable @State var selectedAttachmentImage: UIImage?
    @Previewable @State var pendingInviteURLPreview: String?
    @Previewable @State var sendButtonEnabled: Bool = false
    @Previewable @State var profileImage: UIImage?
    @Previewable @State var isPhotoPickerPresented: Bool = false
    @Previewable @State var onboardingCoordinator: ConversationOnboardingCoordinator = .init()
    @Previewable @FocusState var focusState: MessagesViewInputFocus?
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    @Previewable @State var bottomBarHeight: CGFloat = 0.0

    Group {
        MessagesViewRepresentable(
            conversation: .mock(),
            messages: [],
            invite: .mock(),
            onUserInteraction: {},
            hasLoadedAllMessages: true,
            shouldBlurPhotos: false,
            focusCoordinator: focusCoordinator,
            onTapAvatar: { _ in },
            onLoadPreviousMessages: {},
            onTapInvite: { _ in },
            onReaction: { _, _ in },
            onTapReactions: { _ in },
            onReply: { _ in },
            contextMenuState: .init(),
            onPhotoRevealed: { _ in },
            onPhotoHidden: { _ in },
            onPhotoDimensionsLoaded: { _, _, _ in },
            onAgentOutOfCredits: {},
            onTapUpdateMember: { _ in },
            onRetryMessage: { _ in },
            onDeleteMessage: { _ in },
            onRetryAssistantJoin: {},
            onCopyInviteLink: {},
            onConvoCode: {},
            onInviteAssistant: {},
            onRetryTranscript: { _ in },
            hasAssistant: false,
            isAssistantJoinPending: false,
            isAssistantEnabled: true,
            bottomBarHeight: bottomBarHeight,
            onBottomOverscrollChanged: { _ in },
            onBottomOverscrollReleased: { _ in },
            scrollToBottomTrigger: { _ in }
        )
        .ignoresSafeArea()
    }
    .safeAreaBar(edge: .bottom) {
        MessagesBottomBar(
            profile: profile,
            displayName: $profileName,
            messageText: $messageText,
            selectedAttachmentImage: $selectedAttachmentImage,
            pendingInviteURL: pendingInviteURLPreview,
            sendButtonEnabled: sendButtonEnabled,
            profileImage: $profileImage,
            isPhotoPickerPresented: $isPhotoPickerPresented,
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            onboardingCoordinator: onboardingCoordinator,
            messagesTextFieldEnabled: true,
            onProfilePhotoTap: {
                focusCoordinator.moveFocus(to: .displayName)
            },
            onSendMessage: {},
            onClearInvite: { pendingInviteURLPreview = nil },
            onClearLinkPreview: {},
            onDisplayNameEndedEditing: {
                focusCoordinator.endEditing(for: .displayName)
            },
            onVideoSelected: { _ in },
            onProfileSettings: {},
            onVoiceMemoTap: {},
            voiceMemoRecorder: VoiceMemoRecorder(),
            onSendVoiceMemo: {},
            onConvosAction: {},
            onBaseHeightChanged: { height in
                bottomBarHeight = height
            },
            bottomBarContent: { EmptyView() }
        )
    }
}
