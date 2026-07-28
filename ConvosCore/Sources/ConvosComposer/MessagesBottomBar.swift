#if canImport(UIKit)
import ConvosCore
import ConvosCoreiOS
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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

/// Tracks whether the keyboard is on screen. The composer's stored focus is not
/// a reliable stand-in: the coordinator stops syncing while a focus transition
/// is open, and an interactive dismissal leaves `@FocusState` set with the
/// keyboard already gone (see `FocusCoordinator.refocusNonce`), so each signal
/// lies in one direction. The keyboard itself is the honest one.
private struct KeyboardVisibilityModifier: ViewModifier {
    @Binding var isKeyboardVisible: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                setVisible(true, matching: notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
                setVisible(false, matching: notification)
            }
    }

    /// Carries the keyboard's own duration into the change, so whatever moves
    /// with it travels at the keyboard's pace instead of a spring of its own.
    private func setVisible(_ visible: Bool, matching notification: Notification) {
        let key: String = UIResponder.keyboardAnimationDurationUserInfoKey
        let duration: Double = notification.userInfo?[key] as? Double ?? 0.25
        withAnimation(.easeOut(duration: duration)) {
            isKeyboardVisible = visible
        }
    }
}

/// A single dot breathing in place, holding the participation bubble while the
/// conversation's level is read. It rests at a visible opacity, so if the
/// animation never runs the bubble still reads as occupied rather than empty.
private struct ParticipationLoadingDot: View {
    @State private var isBright: Bool = false

    var body: some View {
        let opacity: Double = isBright ? 0.55 : 0.2
        Circle()
            .fill(Color.colorTextSecondary)
            .frame(width: 6.0, height: 6.0)
            .opacity(opacity)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isBright)
            .onAppear { isBright = true }
    }
}

public struct MessagesBottomBar<BottomBarContent: View, QuickEdit: View, FilePreview: View, AgentChip: View>: View {
    let profile: Profile
    @Binding var displayName: String
    let emptyDisplayNamePlaceholder: String = "Somebody"
    @Binding var messageText: String
    var pendingMediaAttachments: [PendingMediaAttachment] = []
    var composerLinkPreview: LinkPreview?
    var pendingInviteURL: String?
    var pendingInviteIsEditable: Bool = true
    var pendingInviteEmoji: String?
    @Binding var pendingInviteConvoName: String
    @Binding var pendingInviteImage: UIImage?
    var pendingInviteExplodeDuration: ExplodeDuration?
    var onSetInviteExplodeDuration: ((ExplodeDuration?) -> Void)?
    var onInviteConvoNameEditingEnded: ((String) -> Void)?
    var isShowingAgentShareChip: Bool = false
    let sendButtonEnabled: Bool
    @Binding var profileImage: UIImage?
    @Binding var isPhotoPickerPresented: Bool
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    /// Pins the input bar in its expanded (full-width) state and disables the
    /// collapse chevron. Used by hosts without focus-coordinator-driven
    /// expand/collapse, like the share extension.
    let pinsExpandedInput: Bool
    let messagesTextFieldEnabled: Bool
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
    /// `nil` unless `FeatureFlags.isDebugInjectorEnabled` is on (hard-locked off
    /// in production); the testtube button stays hidden in any other case.
    var onDebugAttachmentTap: (() -> Void)?
    let onBaseHeightChanged: (CGFloat) -> Void
    @ViewBuilder let bottomBarContent: () -> BottomBarContent
    /// App-provided quick-edit profile editor shown when the bar expands for
    /// display-name editing. Receives the placeholder text and a binding to
    /// the bar's image-picker presentation state.
    @ViewBuilder let quickEditView: (String, Binding<Bool>) -> QuickEdit
    /// App-provided content for a staged file attachment chip, forwarded to
    /// `MessagesInputView`.
    @ViewBuilder let fileAttachmentPreview: (PendingFileAttachment) -> FilePreview
    /// App-provided chip for a staged agent-share link, forwarded to
    /// `MessagesInputView`.
    @ViewBuilder let agentShareChip: () -> AgentChip

    @State private var voiceMemoKeyboardKeeperText: String = ""
    @State private var isExpanded: Bool = false
    /// Drives the composer's visual swap between the attachment-icon row
    /// (`false`) and the single `+` button beside the large text input
    /// (`true`). Decoupled from actual keyboard focus: it starts `true` so a
    /// freshly opened chat shows the `+` / large-input treatment without
    /// raising the keyboard, and `handleFocusChanged` keeps it in sync with
    /// real focus thereafter.
    @State private var isMessageInputFocused: Bool = true
    @State private var isImagePickerPresented: Bool = false
    @State private var isCameraPresented: Bool = false
    @State private var isFilePickerPresented: Bool = false
    @State private var showFileTooLargeAlert: Bool = false
    @State private var showFileTruncatedAlert: Bool = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var previousFocus: MessagesViewInputFocus?
    @State private var voiceMemoReturnFocus: MessagesViewInputFocus?
    @State private var didSelectPhotoThisSession: Bool = false
    @State private var isKeyboardVisible: Bool = false
    @Namespace private var namespace: Namespace.ID
    // Injected by the host on conversations that hold an agent; nil elsewhere,
    // and the bubble simply isn't drawn.
    @Environment(\.agentParticipation) private var agentParticipation: AgentParticipationContext?

    public init(
        profile: Profile,
        displayName: Binding<String>,
        messageText: Binding<String>,
        pendingMediaAttachments: [PendingMediaAttachment] = [],
        composerLinkPreview: LinkPreview? = nil,
        pendingInviteURL: String? = nil,
        pendingInviteIsEditable: Bool = true,
        pendingInviteEmoji: String? = nil,
        pendingInviteConvoName: Binding<String>,
        pendingInviteImage: Binding<UIImage?>,
        pendingInviteExplodeDuration: ExplodeDuration? = nil,
        onSetInviteExplodeDuration: ((ExplodeDuration?) -> Void)? = nil,
        onInviteConvoNameEditingEnded: ((String) -> Void)? = nil,
        isShowingAgentShareChip: Bool = false,
        sendButtonEnabled: Bool,
        profileImage: Binding<UIImage?>,
        isPhotoPickerPresented: Binding<Bool>,
        focusState: FocusState<MessagesViewInputFocus?>.Binding,
        focusCoordinator: FocusCoordinator,
        pinsExpandedInput: Bool = false,
        messagesTextFieldEnabled: Bool,
        onSendMessage: @escaping () -> Void,
        onClearInvite: @escaping () -> Void,
        onClearLinkPreview: @escaping () -> Void,
        onClearMediaAttachment: @escaping (UUID) -> Void,
        onDisplayNameEndedEditing: @escaping () -> Void,
        onPhotoSelected: @escaping (UIImage) -> Void,
        onVideoSelected: @escaping (URL) -> Void,
        onFileSelected: @escaping (URL, String, String, Int) -> Void,
        onProfileSettings: @escaping () -> Void,
        onVoiceMemoTap: @escaping () -> Void,
        voiceMemoRecorder: VoiceMemoRecorder,
        onSendVoiceMemo: @escaping () -> Void,
        onDebugAttachmentTap: (() -> Void)? = nil,
        onBaseHeightChanged: @escaping (CGFloat) -> Void,
        @ViewBuilder bottomBarContent: @escaping () -> BottomBarContent,
        @ViewBuilder quickEditView: @escaping (String, Binding<Bool>) -> QuickEdit,
        @ViewBuilder fileAttachmentPreview: @escaping (PendingFileAttachment) -> FilePreview,
        @ViewBuilder agentShareChip: @escaping () -> AgentChip
    ) {
        self.profile = profile
        _displayName = displayName
        _messageText = messageText
        self.pendingMediaAttachments = pendingMediaAttachments
        self.composerLinkPreview = composerLinkPreview
        self.pendingInviteURL = pendingInviteURL
        self.pendingInviteIsEditable = pendingInviteIsEditable
        self.pendingInviteEmoji = pendingInviteEmoji
        _pendingInviteConvoName = pendingInviteConvoName
        _pendingInviteImage = pendingInviteImage
        self.pendingInviteExplodeDuration = pendingInviteExplodeDuration
        self.onSetInviteExplodeDuration = onSetInviteExplodeDuration
        self.onInviteConvoNameEditingEnded = onInviteConvoNameEditingEnded
        self.isShowingAgentShareChip = isShowingAgentShareChip
        self.sendButtonEnabled = sendButtonEnabled
        _profileImage = profileImage
        _isPhotoPickerPresented = isPhotoPickerPresented
        _focusState = focusState
        self.focusCoordinator = focusCoordinator
        self.pinsExpandedInput = pinsExpandedInput
        self._isMessageInputFocused = State(initialValue: pinsExpandedInput)
        self.messagesTextFieldEnabled = messagesTextFieldEnabled
        self.onSendMessage = onSendMessage
        self.onClearInvite = onClearInvite
        self.onClearLinkPreview = onClearLinkPreview
        self.onClearMediaAttachment = onClearMediaAttachment
        self.onDisplayNameEndedEditing = onDisplayNameEndedEditing
        self.onPhotoSelected = onPhotoSelected
        self.onVideoSelected = onVideoSelected
        self.onFileSelected = onFileSelected
        self.onProfileSettings = onProfileSettings
        self.onVoiceMemoTap = onVoiceMemoTap
        self.voiceMemoRecorder = voiceMemoRecorder
        self.onSendVoiceMemo = onSendVoiceMemo
        self.onDebugAttachmentTap = onDebugAttachmentTap
        self.onBaseHeightChanged = onBaseHeightChanged
        self.bottomBarContent = bottomBarContent
        self.quickEditView = quickEditView
        self.fileAttachmentPreview = fileAttachmentPreview
        self.agentShareChip = agentShareChip
    }

    var profilePlaceholderText: String {
        "Your name"
    }

    public var body: some View {
        bodyContent
            .modifier(filePickerModifier)
            .modifier(KeyboardVisibilityModifier(isKeyboardVisible: $isKeyboardVisible))
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
            .onChange(of: focusCoordinator.refocusNonce) { _, _ in
                // A same-value re-focus request (e.g. reply/attachment asking for
                // `.message` when the coordinator already holds it) doesn't change
                // `currentFocus`, so re-run the expand/collapse logic here too or
                // the bar would stay collapsed.
                handleFocusChanged(to: focusCoordinator.currentFocus)
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
            isMessageInputFocused = pinsExpandedInput
                || newValue == .message
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

    /// Whether the participation bubble stands aside: it does while the keyboard
    /// is up, so the member typing gets that width back, and comes back the
    /// moment it goes down. Keyed to the keyboard rather than to focus, which
    /// desyncs in both directions - see `KeyboardVisibilityModifier`.
    private var showsParticipationBubble: Bool {
        !isKeyboardVisible
    }

    /// The agent-participation control: how much the agents speak in this
    /// conversation. It leads the composer row, outside the input field, since
    /// it governs the room rather than the message being written — and it steps
    /// aside entirely once someone starts typing.
    @ViewBuilder
    private var participationBubble: some View {
        if let participation = agentParticipation, showsParticipationBubble {
            let bubbleSize: CGFloat = DesignConstants.Spacing.step12x
            let isLoading: Bool = participation.isLoading
            let label: String = isLoading
                ? "Agent participation, loading"
                : "Agent participation: \(participation.level.title)"
            Button(action: participation.onTap) {
                participationGlyph(for: participation)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .opacity(messagesTextFieldEnabled ? 1.0 : 0.4)
            .frame(width: bubbleSize, height: bubbleSize)
            .clipShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
            .transition(.scale.combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: isLoading)
            .accessibilityLabel(label)
            .accessibilityHint("Change how much the agents speak here")
            .accessibilityIdentifier("agent-participation-button")
        }
    }

    /// The icon, or the resting dot that stands in for it. The level starts at a
    /// product default the conversation may not actually be in, so showing an
    /// icon before the read lands would state something that can change a moment
    /// later — the dot says "not known yet" instead.
    @ViewBuilder
    private func participationGlyph(for participation: AgentParticipationContext) -> some View {
        if participation.isLoading {
            ParticipationLoadingDot()
                .frame(width: 32, height: 32)
        } else {
            Image(systemName: participation.level.iconSystemName)
                .font(.system(size: 16.0, weight: .medium))
                .foregroundStyle(Color.colorTextPrimary)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var normalInputView: some View {
        HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step2x) {
            participationBubble

            if isMessageInputFocused {
                Button {
                    withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
                        isMessageInputFocused = false
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18.0, weight: .medium))
                        .foregroundStyle(Color.colorTextPrimary)
                        .frame(width: 32, height: 32)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show attachments")
                .accessibilityIdentifier("collapse-input-button")
                .disabled(pinsExpandedInput)
                .opacity(messagesTextFieldEnabled && !pinsExpandedInput ? 1.0 : 0.4)
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
                MessagesMediaButtonsView(
                    isPhotoPickerPresented: $isPhotoPickerPresented,
                    isCameraPresented: $isCameraPresented,
                    onVoiceMemoTap: startVoiceMemoRecording,
                    onFilePickerTap: {
                        isFilePickerPresented = true
                    },
                    isMediaCapacityFull: mediaButtonsDisabled,
                    isVoiceMemoDisabled: voiceMemoDisabled,
                    onDebugAttachmentTap: onDebugAttachmentTap
                )
                .opacity(messagesTextFieldEnabled ? 1.0 : 0.4)
                .frame(height: DesignConstants.Spacing.step12x)
                .clipShape(.capsule)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("media", in: namespace)
                .glassEffectTransition(.matchedGeometry)
            }

            MessagesInputView(
                displayName: $displayName,
                emptyDisplayNamePlaceholder: emptyDisplayNamePlaceholder,
                messageText: $messageText,
                pendingMediaAttachments: pendingMediaAttachments,
                composerLinkPreview: composerLinkPreview,
                pendingInviteURL: pendingInviteURL,
                pendingInviteIsEditable: pendingInviteIsEditable,
                pendingInviteEmoji: pendingInviteEmoji,
                pendingInviteConvoName: $pendingInviteConvoName,
                pendingInviteImage: $pendingInviteImage,
                pendingInviteExplodeDuration: pendingInviteExplodeDuration,
                onSetInviteExplodeDuration: onSetInviteExplodeDuration,
                onInviteConvoNameEditingEnded: onInviteConvoNameEditingEnded,
                isShowingAgentShareChip: isShowingAgentShareChip,
                sendButtonEnabled: sendButtonEnabled,
                focusState: $focusState,
                messagesTextFieldEnabled: messagesTextFieldEnabled,
                onSendMessage: onSendMessage,
                onClearInvite: onClearInvite,
                onClearLinkPreview: onClearLinkPreview,
                onClearMediaAttachment: onClearMediaAttachment,
                fileAttachmentPreview: fileAttachmentPreview,
                agentShareChip: agentShareChip
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
        quickEditView(profilePlaceholderText, $isImagePickerPresented)
            .frame(maxWidth: 320.0)
            .padding(DesignConstants.Spacing.step6x)
            .clipShape(.rect(cornerRadius: 40.0))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 40.0))
            .glassEffectID("profileEditor", in: namespace)
            .glassEffectTransition(.matchedGeometry)
    }
}
#endif
