import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import PhotosUI
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

private let maxAgentFileAttachmentSizeBytes: Int = 20 * 1024 * 1024

/// Shared identifier used by `AgentDraftComposer`'s glass rect and the
/// in-stream `AgentBuilderSummaryView` so they can match-geometry into
/// each other on commit. Kept in one place to avoid stringly-typed drift.
enum AgentBuilderTransition {
    static let glassEffectId: String = "agentBuilderCard"
}

struct AgentDraftComposer: View {
    @Bindable var viewModel: AgentBuilderViewModel
    var focusState: FocusState<MessagesViewInputFocus?>.Binding
    /// Namespace owned by `AgentBuilderView`; the composer's outer glass
    /// rect applies `glassEffectID("agentBuilderCard", in:)` so it can
    /// morph into the in-stream summary cell on Make.
    let transitionNamespace: Namespace.ID
    let onMakeTap: () -> Void

    @State private var isPhotoPickerPresented: Bool = false
    @State private var isCameraPresented: Bool = false
    @State private var isFilePickerPresented: Bool = false
    @State private var isConnectionsSheetPresented: Bool = false
    @State private var showFileTooLargeAlert: Bool = false
    @State private var showFileTruncatedAlert: Bool = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    private var makeButtonEnabled: Bool {
        viewModel.isMakeEnabled
    }

    private var photoPickerMaxSelectionCount: Int {
        max(0, maxPendingMediaAttachments - viewModel.pendingMediaAttachments.count)
    }

    private var isMediaCapacityFull: Bool {
        viewModel.pendingMediaAttachments.count >= maxPendingMediaAttachments
    }

    var body: some View {
        Group {
            if viewModel.isRecordingVoiceMemo {
                recordingLayout(recorder: viewModel.voiceMemoRecorder)
            } else {
                standardLayout
            }
        }
        .padding(DesignConstants.Spacing.step4x)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        .glassEffectID(AgentBuilderTransition.glassEffectId, in: transitionNamespace)
        .glassEffectTransition(.matchedGeometry)
        .clipShape(.rect(cornerRadius: 24))
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .onTapGesture {
            if !viewModel.isRecordingVoiceMemo {
                focusState.wrappedValue = .agentBuilder
            }
        }
        .opacity(viewModel.isCommitting ? 0 : 1)
        .animation(.easeOut(duration: 0.18), value: viewModel.isCommitting)
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
        .fileImporter(
            isPresented: $isFilePickerPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleFilePickerResult
        )
        .alert("File too large", isPresented: $showFileTooLargeAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Files must be 20 MB or smaller.")
        }
        .alert("Some files weren't added", isPresented: $showFileTruncatedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can attach up to \(maxPendingMediaAttachments) photos, videos, and files in one message.")
        }
        .selfSizingSheet(
            isPresented: $isConnectionsSheetPresented,
            onDismiss: { focusState.wrappedValue = .agentBuilder },
            content: { AgentBuilderConnectionsSheet(viewModel: viewModel) }
        )
    }

    @ViewBuilder
    private var cameraPickerCover: some View {
        CameraPickerView(
            onImageCaptured: { image in
                viewModel.addPhotoAttachment(image)
                isCameraPresented = false
                focusState.wrappedValue = .agentBuilder
            },
            onVideoCaptured: { url in
                viewModel.addVideoAttachment(url: url)
                isCameraPresented = false
                focusState.wrappedValue = .agentBuilder
            }
        )
        .ignoresSafeArea()
    }

    private func handleFilePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let remaining: Int = maxPendingMediaAttachments - viewModel.pendingMediaAttachments.count
            guard remaining > 0 else { return }
            let toStage: [URL] = Array(urls.prefix(remaining))
            if urls.count > toStage.count {
                showFileTruncatedAlert = true
            }
            for url in toStage {
                stageFile(at: url)
            }
            focusState.wrappedValue = .agentBuilder
        case .failure(let error):
            Log.error("Agent builder file picker error: \(error.localizedDescription)")
        }
    }

    private func stageFile(at sourceURL: URL) {
        let didStartAccess: Bool = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize: Int = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize > 0 else {
            Log.error("Agent builder file picker: failed to read size for \(sourceURL.lastPathComponent)")
            return
        }
        guard fileSize <= maxAgentFileAttachmentSizeBytes else {
            showFileTooLargeAlert = true
            return
        }
        let tempURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)
        } catch {
            Log.error("Agent builder file picker: failed to copy file to temp: \(error.localizedDescription)")
            return
        }
        let mimeType: String = UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        viewModel.addFileAttachment(
            url: tempURL,
            filename: sourceURL.lastPathComponent,
            mimeType: mimeType,
            fileSize: fileSize
        )
    }

    private func handleSelectedPhotosChanged(to newValue: [PhotosPickerItem]) {
        guard !newValue.isEmpty else { return }
        let items = newValue
        selectedPhotos = []
        isPhotoPickerPresented = false
        focusState.wrappedValue = .agentBuilder
        Task {
            for item in items {
                if let videoFile = try? await item.loadTransferable(type: VideoFile.self) {
                    await MainActor.run { viewModel.addVideoAttachment(url: videoFile.url) }
                } else if let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) {
                    await MainActor.run { viewModel.addPhotoAttachment(image) }
                }
            }
        }
    }

    private var hasAnyAttachment: Bool {
        !viewModel.pendingMediaAttachments.isEmpty
            || viewModel.recordedVoiceMemo != nil
            || !viewModel.enabledConnections.isEmpty
    }

    private var standardLayout: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            textField
            if hasAnyAttachment {
                attachmentsRow
            }
            bottomRow
        }
    }

    @ViewBuilder
    private func recordingLayout(recorder: VoiceMemoRecorder) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            textField
            Spacer(minLength: 0)
            VoiceMemoRecordingView(recorder: recorder, showsInlineStopButton: false)
                .frame(minHeight: 32)
        }
    }

    private var textFieldPlaceholder: String {
        viewModel.isRecordingVoiceMemo ? "Speaking an agent into existence" : "What needs done?"
    }

    private var textField: some View {
        TextField(
            textFieldPlaceholder,
            text: viewModel.composerTextBinding,
            axis: .vertical
        )
        .focused(focusState, equals: .agentBuilder)
        .font(.body)
        .foregroundStyle(.colorTextPrimary)
        .tint(.colorTextPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel("Agent prompt")
        .accessibilityIdentifier("agent-composer-text-field")
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                if let memo = viewModel.recordedVoiceMemo {
                    VoiceMemoAttachmentChip(
                        url: memo.url,
                        duration: memo.duration,
                        levels: viewModel.voiceMemoAudioLevels
                    ) {
                        viewModel.cancelRecordedVoiceMemo()
                    }
                }
                ForEach(viewModel.pendingMediaAttachments) { attachment in
                    PendingMediaAttachmentChip(attachment: attachment) { id in
                        viewModel.removeAttachment(id: id)
                    }
                }
                ForEach(Array(viewModel.enabledConnections).sorted { $0.id < $1.id }) { connection in
                    ConnectionAttachmentChip(connection: connection) {
                        viewModel.removeConnection(connection)
                    }
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
        }
        .scrollClipDisabled()
        .padding(.horizontal, -DesignConstants.Spacing.step4x)
    }

    private var bottomRow: some View {
        HStack(alignment: .center, spacing: DesignConstants.Spacing.step2x) {
            scrollableMediaButtons
            makeButton
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Horizontally scrolling media-button strip with fade caps on both ends.
    /// Lets the Make button keep its intrinsic width on narrow screens (iPhone
    /// mini) without truncating to "M…" — the icons scroll instead. Mirrors
    /// the pattern used by `ReadReceiptAvatarsView`.
    private var scrollableMediaButtons: some View {
        let fadeWidth: CGFloat = DesignConstants.Spacing.step3x
        return ScrollView(.horizontal, showsIndicators: false) {
            MessagesMediaButtonsView(
                isPhotoPickerPresented: $isPhotoPickerPresented,
                isCameraPresented: $isCameraPresented,
                onVoiceMemoTap: {
                    let composerWasFocused = focusState.wrappedValue == .agentBuilder
                    focusState.wrappedValue = nil
                    viewModel.startVoiceMemoRecording(restoreComposerFocusAfter: composerWasFocused)
                },
                onFilePickerTap: {
                    focusState.wrappedValue = nil
                    isFilePickerPresented = true
                },
                isMediaCapacityFull: isMediaCapacityFull,
                isVoiceMemoDisabled: viewModel.recordedVoiceMemo != nil,
                showsFileButton: false,
                buttonSpacing: DesignConstants.Spacing.step4x,
                onConnectionsTap: {
                    focusState.wrappedValue = nil
                    isConnectionsSheetPresented = true
                }
            )
            .padding(.horizontal, fadeWidth)
        }
        .scrollClipDisabled()
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mask(
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0), .black],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: fadeWidth)
                Rectangle().fill(.black)
                LinearGradient(
                    colors: [.black, .black.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: fadeWidth)
            }
        )
        .padding(.leading, -DesignConstants.Spacing.step2x)
    }

    private var makeButton: some View {
        Button {
            onMakeTap()
        } label: {
            Text("Make")
                .font(.callout)
                .foregroundStyle(makeButtonEnabled ? .colorTextPrimaryInverted : .colorTextTertiary)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .frame(height: 36)
                .background(makeButtonEnabled ? Color.colorFillPrimary : Color.colorFillMinimal)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!makeButtonEnabled)
        .accessibilityLabel("Make agent")
        .accessibilityIdentifier("agent-make-button")
    }
}

/// Insertion / removal modifier used by `PendingMediaAttachmentChip`.
/// `active` is the "poofed out" pose — scaled up, blurred, fully
/// transparent. Identity is the settled pose. The chip's existing
/// state-driven remove flow keeps using this pose directly; the
/// `AnyTransition.chipPoof` below pairs it with `.identity` so insertions
/// animate in by reversing the same modifier.
private struct ChipPoofModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 1.3 : 1.0)
            .blur(radius: active ? 12.0 : 0.0)
            .opacity(active ? 0.0 : 1.0)
    }
}

extension AnyTransition {
    static var chipPoof: AnyTransition {
        .modifier(
            active: ChipPoofModifier(active: true),
            identity: ChipPoofModifier(active: false)
        )
    }
}

struct PendingMediaAttachmentChip: View {
    let attachment: PendingMediaAttachment
    let onClear: (UUID) -> Void

    private let chipSize: CGFloat = 80.0
    @State private var isPoofing: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            chipContent
            removeButton
        }
        .scaleEffect(isPoofing ? 1.3 : 1.0)
        .blur(radius: isPoofing ? 12.0 : 0.0)
        .opacity(isPoofing ? 0.0 : 1.0)
        // Insertion only — the existing `isPoofing` state drives the
        // removal animation manually (so the chip can dwell at the
        // poofed-out pose for 200ms before being removed from the array).
        .transition(.asymmetric(insertion: .chipPoof, removal: .identity))
    }

    private func triggerRemoval() {
        guard !isPoofing else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            isPoofing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onClear(attachment.id)
        }
    }

    @ViewBuilder
    private var chipContent: some View {
        switch attachment {
        case .photo(let photo):
            photoVideoChip(image: photo.image, isVideo: false)
        case .video(let video):
            photoVideoChip(image: video.thumbnail, isVideo: true)
        case .file(let file):
            fileChip(file: file)
        }
    }

    @ViewBuilder
    private func photoVideoChip(image: UIImage?, isVideo: Bool) -> some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.colorFillSubtle
            }
        }
        .frame(width: chipSize, height: chipSize)
        .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
        .overlay(alignment: .bottomLeading) {
            if isVideo {
                Image(systemName: "video.fill")
                    .font(.system(size: 16.0, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    .padding(.bottom, DesignConstants.Spacing.step2x)
                    .padding(.leading, DesignConstants.Spacing.step2x)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(isVideo ? "Video attachment preview" : "Photo attachment preview")
        .accessibilityIdentifier("agent-attachment-preview")
    }

    @ViewBuilder
    private func fileChip(file: PendingFileAttachment) -> some View {
        FileAttachmentChipPreview(file: file, size: chipSize)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-file-attachment-preview")
    }

    private var removeButton: some View {
        Button {
            triggerRemoval()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10.0, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20.0, height: 20.0)
                .background(.black)
                .clipShape(.circle)
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1.0))
        }
        .padding(.top, DesignConstants.Spacing.step2x)
        .padding(.trailing, DesignConstants.Spacing.step2x)
        .accessibilityLabel("Remove attachment")
        .accessibilityIdentifier("remove-agent-attachment-button")
    }
}

private struct ConnectionAttachmentChip: View {
    let connection: AgentBuilderConnection
    let onRemove: () -> Void

    @State private var isPoofing: Bool = false

    private let chipSize: CGFloat = 80.0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(connection.chipImageName)
                .resizable()
                .scaledToFit()
                .frame(width: chipSize, height: chipSize)
                .accessibilityLabel("\(connection.displayName) connection attachment")
                .accessibilityIdentifier("connection-attachment-\(connection.id)")

            Button {
                triggerRemoval()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.0, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20.0, height: 20.0)
                    .background(.black)
                    .clipShape(.circle)
                    .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1.0))
            }
            .padding(.top, DesignConstants.Spacing.step2x)
            .padding(.trailing, DesignConstants.Spacing.step2x)
            .accessibilityLabel("Remove \(connection.displayName) connection")
            .accessibilityIdentifier("remove-connection-\(connection.id)-button")
        }
        .scaleEffect(isPoofing ? 1.3 : 1.0)
        .blur(radius: isPoofing ? 12.0 : 0.0)
        .opacity(isPoofing ? 0.0 : 1.0)
    }

    private func triggerRemoval() {
        withAnimation(.easeOut(duration: 0.2)) {
            isPoofing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onRemove()
        }
    }
}

private struct FileAttachmentChipPreview: View {
    let file: PendingFileAttachment
    let size: CGFloat

    @Environment(\.displayScale) private var displayScale: CGFloat
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(.colorFillSubtle)
        .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
        .task(id: file.id) {
            await loadThumbnail()
        }
    }

    private var fallback: some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Image(systemName: "doc.fill")
                .font(.system(size: 28))
                .foregroundStyle(.colorTextSecondary)
            Text(file.filename)
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, DesignConstants.Spacing.step2x)
    }

    @MainActor
    private func loadThumbnail() async {
        let request: QLThumbnailGenerator.Request = QLThumbnailGenerator.Request(
            fileAt: file.url,
            size: CGSize(width: size, height: size),
            scale: displayScale,
            representationTypes: .thumbnail
        )
        do {
            let result = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            thumbnail = result.uiImage
        } catch {
            // no preview available — keep fallback
        }
    }
}

#Preview {
    @Previewable @State var viewModel: AgentBuilderViewModel = .init(
        session: ConvosClient.mock().session
    )
    @Previewable @FocusState var focusState: MessagesViewInputFocus?
    @Previewable @Namespace var namespace: Namespace.ID
    AgentDraftComposer(
        viewModel: viewModel,
        focusState: $focusState,
        transitionNamespace: namespace,
        onMakeTap: {}
    )
    .padding()
}
