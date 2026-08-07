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
    let messagePlaceholder: String
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
        messagePlaceholder: String = "Chat",
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
        self.messagesTextFieldEnabled = messagesTextFieldEnabled
        self.messagePlaceholder = messagePlaceholder
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

    /// The agent-participation control: how much the agents speak in this
    /// conversation. It leads the composer row, outside the input field, since
    /// it governs the room rather than the message being written, and stays put
    /// while someone types so the level is always readable and reachable.
    @ViewBuilder
    private var participationBubble: some View {
        if let participation = agentParticipation {
            let bubbleSize: CGFloat = DesignConstants.Spacing.step12x
            let isLoading: Bool = participation.isLoading
            let label: String = isLoading
                ? "Agent participation, loading"
                : "Agent participation: \(participation.level.title)"
            // The glyph is drawn inert on the glass, with an invisible menu
            // hit-target over it - the same split the attachments `+` uses.
            // iOS opens a menu by morphing the glass that holds its label, so a
            // label that is the glyph gets lifted into that morph. On its own
            // that is invisible; it shows when this menu and the attachments
            // menu are worked in quick succession, because the second morph
            // starts while the first is still unwinding and the glyph jumps
            // between them. Leaving a beat between the two hid it, which is
            // what identified the overlap. Out of the menu, the glyph takes
            // part in neither morph and overlapping presentations can't move
            // it.
            ParticipationGlyph(level: participation.level, isLoading: isLoading)
                .frame(width: bubbleSize, height: bubbleSize)
                .clipShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
                .overlay {
                    ParticipationMenuControl(
                        level: participation.level,
                        isLoading: isLoading,
                        onSelect: participation.onSelect
                    )
                    .equatable()
                }
                .disabled(isLoading)
                .opacity(messagesTextFieldEnabled ? 1.0 : 0.4)
                .transition(.scale.combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: isLoading)
                .accessibilityLabel(label)
                .accessibilityHint("Change how much the agents speak here")
                .accessibilityIdentifier("agent-participation-button")
        }
    }

    /// The rows the menu draws. The debug injector joins them only where the
    /// host handed one over, which it does behind `isDebugInjectorEnabled` -
    /// hard-locked off in production, so no member ever sees the row.
    private var offeredAttachmentActions: [ComposerAttachmentAction] {
        guard onDebugAttachmentTap != nil else { return ComposerAttachmentAction.standard }
        return ComposerAttachmentAction.standard + [.debugInjector]
    }

    /// What the composer can't offer right now. The menu greys these rows rather
    /// than dropping them, so the list doesn't change length as attachments come
    /// and go and a member can see why an option is unavailable.
    private var disabledAttachmentActions: Set<ComposerAttachmentAction> {
        let hasSideConvo: Bool = pendingInviteURL != nil
        let hasMedia: Bool = !pendingMediaAttachments.isEmpty
        let isMediaCapacityFull: Bool = pendingMediaAttachments.count >= maxPendingMediaAttachments
        var disabled: Set<ComposerAttachmentAction> = []
        if isMediaCapacityFull || hasSideConvo {
            disabled.formUnion([.photos, .camera, .files])
        }
        if hasMedia || hasSideConvo {
            disabled.insert(.voiceNote)
        }
        return disabled
    }

    /// The `+` as it appears inside the input field: just the glyph, inert. The
    /// tappable control is `attachmentsControl`, overlaid in the same spot -
    /// the glyph and the control are split because each needs a different side
    /// of the field's glass. The glyph must live under it, on the capsule's own
    /// surface, or it renders washed out; the menu's button must live outside
    /// it, or the system opens the menu by morphing the whole capsule rather
    /// than growing a card from the `+` alone.
    private var attachmentsGlyph: some View {
        let glyphOpacity: Double = pinsExpandedInput ? 0.4 : 1.0
        return Image(systemName: "plus")
            .font(.system(size: 18.0, weight: .medium))
            .foregroundStyle(Color.colorTextPrimary)
            .frame(width: 32, height: 32)
            .opacity(glyphOpacity)
    }

    /// The control that opens the attachments menu: an invisible hit target
    /// floating right over `attachmentsGlyph`. A system menu rather than a
    /// hand-rolled card: it presents in its own window, so the bar's bounds
    /// can't clip it, and the spring, haptic, dimming, and drag-to-select all
    /// come with it.
    private var attachmentsControl: some View {
        AttachmentsMenuControl(
            offeredActions: offeredAttachmentActions,
            disabledActions: disabledAttachmentActions,
            isDisabled: pinsExpandedInput,
            onSelect: handleAttachmentSelected
        )
        .equatable()
    }

    /// Runs the picked row. The menu has already dismissed by the time the
    /// action fires, so a picker can present right away.
    private func handleAttachmentSelected(_ action: ComposerAttachmentAction) {
        switch action {
        case .photos: isPhotoPickerPresented = true
        case .camera: isCameraPresented = true
        case .files: isFilePickerPresented = true
        case .voiceNote: startVoiceMemoRecording()
        case .debugInjector: onDebugAttachmentTap?()
        }
    }

    @ViewBuilder
    private var normalInputView: some View {
        HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step2x) {
            participationBubble

            MessagesInputView(
                displayName: $displayName,
                emptyDisplayNamePlaceholder: emptyDisplayNamePlaceholder,
                messagePlaceholder: messagePlaceholder,
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
                agentShareChip: agentShareChip,
                attachmentsButton: { attachmentsGlyph }
            )
            .opacity(messagesTextFieldEnabled ? 1.0 : 0.4)
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(.rect(cornerRadius: 26.0))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26.0))
            .glassEffectID("input", in: namespace)
            .glassEffectTransition(.matchedGeometry)
            .overlay(alignment: .bottomLeading) {
                attachmentsControl
                    .padding(DesignConstants.Spacing.step2x)
            }
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

/// The attachments menu, isolated behind `Equatable` so the bar's re-renders
/// can't touch it while it is presented. SwiftUI pushes a rebuilt menu into a
/// visible menu on every re-evaluation of this subtree, and UIKit throws
/// (`UIFocusSystem` inconsistency) if such a push lands right as hardware-
/// keyboard focus settles on a menu row - which is exactly what happens when
/// opening the menu makes the keyboard dismiss and the bar re-lay out. With
/// `.equatable()`, the subtree only re-evaluates when the menu's actual
/// content changes.
private struct AttachmentsMenuControl: View, Equatable {
    let offeredActions: [ComposerAttachmentAction]
    let disabledActions: Set<ComposerAttachmentAction>
    let isDisabled: Bool
    let onSelect: (ComposerAttachmentAction) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.offeredActions == rhs.offeredActions &&
            lhs.disabledActions == rhs.disabledActions &&
            lhs.isDisabled == rhs.isDisabled
    }

    var body: some View {
        Menu {
            ForEach(offeredActions) { action in
                row(for: action)
            }
        } label: {
            Color.clear
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Show attachments")
        .accessibilityIdentifier("attachments-button")
        .disabled(isDisabled)
    }

    /// One row of the menu. Rows the composer can't offer right now are greyed
    /// rather than dropped, so the list doesn't change length as attachments
    /// come and go.
    private func row(for action: ComposerAttachmentAction) -> some View {
        let select = { onSelect(action) }
        return Button(action: select) {
            Text(action.title)
            Image(systemName: action.iconSystemName)
        }
        .disabled(disabledActions.contains(action))
        .accessibilityIdentifier("attachment-\(action.rawValue)-button")
    }
}

/// The participation bubble's menu: the levels as a system menu, with a check
/// on the one the conversation is in. `Equatable` for the same reason as
/// `AttachmentsMenuControl` - the bar's re-renders must not push a rebuilt
/// menu into one that is already presented.
private struct ParticipationMenuControl: View, Equatable {
    let level: AgentParticipationLevel
    let isLoading: Bool
    let onSelect: (AgentParticipationLevel) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.level == rhs.level && lhs.isLoading == rhs.isLoading
    }

    var body: some View {
        Menu {
            Section("Agent participation") {
                ForEach(AgentParticipationLevel.selectableCases) { option in
                    row(for: option)
                }
            }
        } label: {
            Color.clear
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .menuOrder(.fixed)
    }

    /// One level as a menu row. A toggle rather than a button so the system
    /// draws the leading check on the current level while the trailing slot
    /// keeps the level's own icon.
    private func row(for option: AgentParticipationLevel) -> some View {
        let isOn = Binding<Bool>(
            get: { option == level },
            set: { selected in
                guard selected else { return }
                onSelect(option)
            }
        )
        return Toggle(isOn: isOn) {
            Text(option.title)
            Text(option.caption)
            Image(systemName: option.iconSystemName)
        }
        .accessibilityIdentifier("participation-\(option.rawValue)-row")
    }
}

/// The icon, or the resting dot that stands in for it. The level starts at a
/// product default the conversation may not actually be in, so showing an
/// icon before the read lands would state something that can change a moment
/// later - the dot says "not known yet" instead.
///
/// Drawn outside the menu so opening the menu never lifts it into the morph.
private struct ParticipationGlyph: View {
    let level: AgentParticipationLevel
    let isLoading: Bool

    @ViewBuilder
    var body: some View {
        if isLoading {
            ParticipationLoadingDot()
                .frame(width: 32, height: 32)
        } else {
            Image(systemName: level.iconSystemName)
                .font(.system(size: 16.0, weight: .medium))
                .foregroundStyle(Color.colorTextPrimary)
                .frame(width: 32, height: 32)
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.2), value: level)
        }
    }
}
#endif
