import ConvosCore
import ConvosCoreiOS
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum MessagesViewInputFocus: Hashable {
    case message, displayName, conversationName, voiceMemoRecording, sideConvoName
}

private let maxFileAttachmentSizeBytes: Int = 20 * 1024 * 1024

private struct FilePickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var showTooLargeAlert: Bool
    @Binding var showTruncatedAlert: Bool
    let onResult: (Result<[URL], Error>) -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onCompletion: onResult
            )
            .alert("File too large", isPresented: $showTooLargeAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Files must be 20 MB or smaller.")
            }
            .alert("Some files weren't added", isPresented: $showTruncatedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You can attach up to \(maxPendingMediaAttachments) photos, videos, and files in one message.")
            }
    }
}

struct MessagesBottomBar<BottomBarContent: View>: View {
    let profile: Profile
    @Binding var displayName: String
    let emptyDisplayNamePlaceholder: String = "Somebody"
    @Binding var messageText: String
    var pendingMediaAttachments: [PendingMediaAttachment] = []
    var composerLinkPreview: LinkPreview?
    var pendingInviteURL: String?
    var pendingInviteEmoji: String?
    @Binding var pendingInviteConvoName: String
    @Binding var pendingInviteImage: UIImage?
    var pendingInviteExplodeDuration: ExplodeDuration?
    var onSetInviteExplodeDuration: ((ExplodeDuration?) -> Void)?
    var onInviteConvoNameEditingEnded: ((String) -> Void)?
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
    let onClearMediaAttachment: (UUID) -> Void
    let onDisplayNameEndedEditing: () -> Void
    let onPhotoSelected: (UIImage) -> Void
    let onVideoSelected: (URL) -> Void
    let onFileSelected: (URL, String, String, Int) -> Void
    let onProfileSettings: () -> Void
    let onVoiceMemoTap: () -> Void
    @Bindable var voiceMemoRecorder: VoiceMemoRecorder
    let onSendVoiceMemo: () -> Void
    let onConvosAction: () -> Void
    let onBaseHeightChanged: (CGFloat) -> Void
    @ViewBuilder let bottomBarContent: () -> BottomBarContent

    @State private var profileSettings: ProfileSettingsViewModel = .shared

    @State private var voiceMemoKeyboardKeeperText: String = ""
    @State private var isExpanded: Bool = false
    @State private var isMessageInputFocused: Bool = false
    @State private var isImagePickerPresented: Bool = false
    @State private var isCameraPresented: Bool = false
    @State private var isFilePickerPresented: Bool = false
    @State private var showFileTooLargeAlert: Bool = false
    @State private var showFileTruncatedAlert: Bool = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var previousFocus: MessagesViewInputFocus?
    @State private var voiceMemoReturnFocus: MessagesViewInputFocus?
    @State private var didSelectPhotoThisSession: Bool = false
    @Namespace private var namespace: Namespace.ID

    var profilePlaceholderText: String {
        onboardingCoordinator.state == .settingUpProfile ? "Add your name" : "Your name"
    }

    var body: some View {
        bodyContent
            .modifier(filePickerModifier)
    }

    @ViewBuilder
    private var bodyContent: some View {
        bodyStack
            .background(HeightReader())
            .onPreferenceChange(HeightPreferenceKey.self) { height in
                onBaseHeightChanged(height)
            }
            .onChange(of: focusCoordinator.currentFocus) { _, newValue in
                handleFocusChanged(to: newValue)
            }
            .onChange(of: messageText) { _, _ in
                handleMessageTextChanged()
            }
            .onChange(of: isVoiceMemoActive) { wasActive, isActive in
                guard wasActive, !isActive else { return }
                restoreVoiceMemoFocusIfNeeded()
            }
            .onChange(of: isPhotoPickerPresented) { _, newValue in
                handlePhotoPickerPresentationChanged(to: newValue)
            }
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $selectedPhotos,
                maxSelectionCount: photoPickerMaxSelectionCount,
                matching: .any(of: [.images, .videos])
            )
            .onChange(of: selectedPhotos) { _, newValue in
                handleSelectedPhotosChanged(to: newValue)
            }
            .fullScreenCover(isPresented: $isCameraPresented) {
                cameraPickerCover
            }
    }

    @ViewBuilder
    private var bodyStack: some View {
        VStack(spacing: 0) {
            bottomBarContent()
            VoiceMemoKeyboardFocusKeeper(
                focusState: $focusState,
                text: $voiceMemoKeyboardKeeperText
            )
            GlassEffectContainer {
                ZStack {
                    if isExpanded {
                        expandedQuickEditView
                    } else {
                        collapsedInputView
                    }
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.top, DesignConstants.Spacing.step2x)
            .padding(.bottom, DesignConstants.Spacing.step4x)
        }
    }

    private var photoPickerMaxSelectionCount: Int {
        max(1, maxPendingMediaAttachments - pendingMediaAttachments.count)
    }

    @ViewBuilder
    private var cameraPickerCover: some View {
        CameraPickerView(
            onImageCaptured: { image in
                onPhotoSelected(image)
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

    private func handleFocusChanged(to newValue: MessagesViewInputFocus?) {
        guard !isImagePickerPresented else { return }
        withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
            isExpanded = newValue == .displayName
            isMessageInputFocused = newValue == .message
                || newValue == .voiceMemoRecording
                || newValue == .sideConvoName
        }
    }

    private func handleMessageTextChanged() {
        guard !isMessageInputFocused, focusCoordinator.currentFocus != .displayName else { return }
        withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
            isMessageInputFocused = true
        }
    }

    private func handlePhotoPickerPresentationChanged(to newValue: Bool) {
        if newValue {
            previousFocus = focusCoordinator.currentFocus
            didSelectPhotoThisSession = false
            focusState = nil
        } else if !didSelectPhotoThisSession, let previousFocus {
            focusCoordinator.moveFocus(to: previousFocus)
        }
    }

    private func handleSelectedPhotosChanged(to newValue: [PhotosPickerItem]) {
        guard !newValue.isEmpty else { return }
        let items = newValue
        selectedPhotos = []
        didSelectPhotoThisSession = true
        isPhotoPickerPresented = false
        focusCoordinator.moveFocus(to: .message)
        Task {
            for item in items {
                if let videoFile = try? await item.loadTransferable(type: VideoFile.self) {
                    await MainActor.run { onVideoSelected(videoFile.url) }
                } else if let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) {
                    await MainActor.run { onPhotoSelected(image) }
                }
            }
        }
    }

    private var filePickerModifier: FilePickerModifier {
        FilePickerModifier(
            isPresented: $isFilePickerPresented,
            showTooLargeAlert: $showFileTooLargeAlert,
            showTruncatedAlert: $showFileTruncatedAlert,
            onResult: handleFileImporterResult
        )
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let remaining = maxPendingMediaAttachments - pendingMediaAttachments.count
            guard remaining > 0 else { return }
            let toStage = Array(urls.prefix(remaining))
            if urls.count > toStage.count {
                showFileTruncatedAlert = true
            }
            for url in toStage {
                stageFile(at: url)
            }
        case .failure(let error):
            Log.error("File picker error: \(error)")
        }
    }

    private func stageFile(at sourceURL: URL) {
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize > 0 else {
            Log.error("File picker: failed to read file size for \(sourceURL.lastPathComponent)")
            return
        }
        guard fileSize <= maxFileAttachmentSizeBytes else {
            showFileTooLargeAlert = true
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)
        } catch {
            Log.error("Failed to copy picked file to temp: \(error)")
            return
        }

        let mimeType = UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"

        onFileSelected(tempURL, sourceURL.lastPathComponent, mimeType, fileSize)
        focusCoordinator.moveFocus(to: .message)
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
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.colorCaution)
                        .frame(width: DesignConstants.Spacing.step11x, height: DesignConstants.Spacing.step11x)
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
                let hasSideConvo: Bool = pendingInviteURL != nil
                let hasMedia: Bool = !pendingMediaAttachments.isEmpty
                let isMediaCapacityFull: Bool = pendingMediaAttachments.count >= maxPendingMediaAttachments
                let mediaButtonsDisabled: Bool = isMediaCapacityFull || hasSideConvo
                let voiceMemoDisabled: Bool = hasMedia || hasSideConvo
                let sideConvoDisabled: Bool = hasSideConvo || hasMedia
                MessagesMediaButtonsView(
                    isPhotoPickerPresented: $isPhotoPickerPresented,
                    isCameraPresented: $isCameraPresented,
                    onVoiceMemoTap: startVoiceMemoRecording,
                    onFilePickerTap: {
                        isFilePickerPresented = true
                    },
                    onConvosAction: {
                        guard pendingInviteURL == nil else { return }
                        withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
                            isMessageInputFocused = true
                        }
                        onConvosAction()
                    },
                    isMediaCapacityFull: mediaButtonsDisabled,
                    isVoiceMemoDisabled: voiceMemoDisabled,
                    isSideConvoDisabled: sideConvoDisabled
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
                pendingMediaAttachments: pendingMediaAttachments,
                composerLinkPreview: composerLinkPreview,
                pendingInviteURL: pendingInviteURL,
                pendingInviteEmoji: pendingInviteEmoji,
                pendingInviteConvoName: $pendingInviteConvoName,
                pendingInviteImage: $pendingInviteImage,
                pendingInviteExplodeDuration: pendingInviteExplodeDuration,
                onSetInviteExplodeDuration: onSetInviteExplodeDuration,
                onInviteConvoNameEditingEnded: onInviteConvoNameEditingEnded,
                sendButtonEnabled: sendButtonEnabled,
                focusState: $focusState,
                animateAvatarForProfileSetup: onboardingCoordinator.shouldAnimateAvatarForProfileSetup,
                messagesTextFieldEnabled: messagesTextFieldEnabled,
                isCollapsed: !isMessageInputFocused,
                canEditProfile: profileSettings.profileSettings.isDefault,
                onProfilePhotoTap: onProfilePhotoTap,
                onSendMessage: onSendMessage,
                onClearInvite: onClearInvite,
                onClearLinkPreview: onClearLinkPreview,
                onClearMediaAttachment: onClearMediaAttachment
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
            placeholderText: profilePlaceholderText,
            text: $displayName,
            image: $profileImage,
            isImagePickerPresented: $isImagePickerPresented,
            imageAssetIdentifier: Binding(
                get: { profileSettings.profileImageAssetIdentifier },
                set: { profileSettings.profileImageAssetIdentifier = $0 }
            ),
            focusState: $focusState,
            focused: .displayName,
            settingsSymbolName: "lanyardcard.fill",
            showsSettingsButton: false,
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
            onToggleReaction: { _, _ in },
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
            profileSheetForMember: { _ in AnyView(EmptyView()) },
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
            pendingInviteURL: pendingInviteURLPreview,
            pendingInviteConvoName: .constant(""),
            pendingInviteImage: .constant(nil),
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
            onClearMediaAttachment: { _ in },
            onDisplayNameEndedEditing: {
                focusCoordinator.endEditing(for: .displayName)
            },
            onPhotoSelected: { _ in },
            onVideoSelected: { _ in },
            onFileSelected: { _, _, _, _ in },
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
