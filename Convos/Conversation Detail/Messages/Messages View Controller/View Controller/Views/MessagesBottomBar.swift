import ConvosCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum MessagesViewInputFocus: Hashable {
    case message, displayName, conversationName
}

struct MessagesBottomBar<BottomBarContent: View>: View {
    let profile: Profile
    @Binding var displayName: String
    let emptyDisplayNamePlaceholder: String = "Somebody"
    @Binding var messageText: String
    @Binding var selectedAttachmentImage: UIImage?
    var pendingInviteCode: String?
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
    let onDisplayNameEndedEditing: () -> Void
    let onVideoSelected: (URL) -> Void
    let onProfileSettings: () -> Void
    let onBaseHeightChanged: (CGFloat) -> Void
    @ViewBuilder let bottomBarContent: () -> BottomBarContent

    @State private var quicknameSettings: QuicknameSettingsViewModel = .shared

    @State private var isExpanded: Bool = false
    @State private var isImagePickerPresented: Bool = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var previousFocus: MessagesViewInputFocus?
    @State private var didSelectPhotoThisSession: Bool = false
    @Namespace private var namespace: Namespace.ID

    var quicknamePlaceholderText: String {
        onboardingCoordinator.state == .settingUpQuickname ? "Add your name" : "Your name"
    }

    var body: some View {
        VStack(spacing: 0) {
            bottomBarContent()
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
                isExpanded = newValue == .displayName ? true : false
            }
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
    }

    @ViewBuilder
    private var collapsedInputView: some View {
        HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step2x) {
            MessagesMediaInputView(isPhotoPickerPresented: $isPhotoPickerPresented)
                .opacity(messagesTextFieldEnabled ? 1.0 : 0.4)
                .frame(width: DesignConstants.Spacing.step12x, height: DesignConstants.Spacing.step12x)
                .clipShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("media", in: namespace)

            MessagesInputView(
                profile: profile,
                profileImage: $profileImage,
                displayName: $displayName,
                emptyDisplayNamePlaceholder: emptyDisplayNamePlaceholder,
                messageText: $messageText,
                selectedAttachmentImage: $selectedAttachmentImage,
                pendingInviteCode: pendingInviteCode,
                sendButtonEnabled: sendButtonEnabled,
                focusState: $focusState,
                animateAvatarForQuickname: onboardingCoordinator.shouldAnimateAvatarForQuicknameSetup,
                messagesTextFieldEnabled: messagesTextFieldEnabled,
                onProfilePhotoTap: onProfilePhotoTap,
                onSendMessage: onSendMessage,
                onClearInvite: onClearInvite
            )
            .opacity(messagesTextFieldEnabled ? 1.0 : 0.4)
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(.rect(cornerRadius: 26.0))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26.0))
            .glassEffectID("input", in: namespace)
            .glassEffectTransition(.matchedGeometry)
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

struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let tempDir = FileManager.default.temporaryDirectory
            let outputURL = tempDir.appendingPathComponent("video_\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: outputURL)
            return VideoFile(url: outputURL)
        }
    }
}

#Preview {
    @Previewable @State var profile: Profile = .mock()
    @Previewable @State var profileName: String = ""
    @Previewable @State var messageText: String = ""
    @Previewable @State var selectedAttachmentImage: UIImage?
    @Previewable @State var pendingInviteCodePreview: String?
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
            onAboutAssistants: {},
            onAgentOutOfCredits: {},
            onRetryMessage: { _ in },
            onDeleteMessage: { _ in },
            onRetryAssistantJoin: {},
            bottomBarHeight: bottomBarHeight,
            onBottomOverscrollChanged: { _ in },
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
            pendingInviteCode: pendingInviteCodePreview,
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
            onClearInvite: { pendingInviteCodePreview = nil },
            onDisplayNameEndedEditing: {
                focusCoordinator.endEditing(for: .displayName)
            },
            onVideoSelected: { _ in },
            onProfileSettings: {},
            onBaseHeightChanged: { height in
                bottomBarHeight = height
            },
            bottomBarContent: { EmptyView() }
        )
    }
}
