import ConvosComposer
import ConvosCore
import PhotosUI
import SwiftUI
import UIKit

struct DocPhotoLoadGate: Equatable {
    private(set) var pendingCount: Int = 0

    var isLoading: Bool { pendingCount > 0 }

    mutating func begin(count: Int) {
        pendingCount += max(0, count)
    }

    mutating func finishOne() {
        pendingCount = max(0, pendingCount - 1)
    }

    func canSend(isReady: Bool, isSending: Bool, hasPayload: Bool) -> Bool {
        isReady && !isSending && !isLoading && hasPayload
    }
}

/// Doc's small fork of `ConversationComposerBar` / `MessagesBottomBar`.
/// The input capsule, attachment placement, glass construction, spacing, and
/// send treatment stay identical to the conversation composer; Doc adds only
/// its History bubble and unlimited screenshot selection.
struct DocComposerBar: View {
    enum ActionKind: Hashable {
        case history
        case photos
        case send
    }

    static let renderedActionKinds: [ActionKind] = [.history, .photos, .send]

    @Bindable var viewModel: DocExperienceViewModel
    let scope: DocComposerScope
    let messagePlaceholder: String
    var showsReadingProgress: Bool = false

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isSending: Bool = false
    @State private var didFail: Bool = false
    @State private var photoLoadGate: DocPhotoLoadGate = .init()
    @FocusState private var focusState: MessagesViewInputFocus?
    @Namespace private var namespace: Namespace.ID

    private var messageText: Binding<String> {
        Binding(
            get: { viewModel.composerText(in: scope) },
            set: { viewModel.setComposerText($0, in: scope) }
        )
    }

    private var pendingPhotos: [DocPendingPhoto] {
        viewModel.pendingPhotos(in: scope)
    }

    private var pendingMediaAttachments: [PendingMediaAttachment] {
        pendingPhotos.map { photo in
            .photo(PendingPhotoAttachment(id: photo.id, image: photo.image))
        }
    }

    private var isReady: Bool {
        viewModel.isComposerReady(in: scope)
    }

    private var canSend: Bool {
        let cleanText = viewModel.composerText(in: scope)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return photoLoadGate.canSend(
            isReady: isReady,
            isSending: isSending,
            hasPayload: !cleanText.isEmpty || !pendingPhotos.isEmpty
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusContent
            GlassEffectContainer {
                HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step2x) {
                    historyBubble
                    inputCapsule
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.top, DesignConstants.Spacing.step2x)
            .padding(.bottom, DesignConstants.Spacing.step4x)
        }
        .onChange(of: selectedPhotos) { _, photos in
            load(photos)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if showsReadingProgress, viewModel.pendingScreenshotCount > 0 {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                ProgressView()
                    .controlSize(.small)
                Text(progressText)
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(.colorTextSecondary)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .frame(minHeight: 32.0)
            .background(.colorFillMinimal, in: Capsule())
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .accessibilityIdentifier("doc-reading-progress")
        }

        if photoLoadGate.isLoading {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                ProgressView()
                    .controlSize(.small)
                Text(photoLoadingText)
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(.colorTextSecondary)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .frame(minHeight: 32.0)
            .background(.colorFillMinimal, in: Capsule())
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .accessibilityIdentifier("doc-photo-loading")
        }

        if didFail {
            Text("Couldn't send. Try again.")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .accessibilityIdentifier(sendErrorIdentifier)
        }
    }

    private var progressText: String {
        let count = viewModel.pendingScreenshotCount
        return "Doc is reading \(count) screenshot\(count == 1 ? "" : "s")…"
    }

    private var photoLoadingText: String {
        let count = photoLoadGate.pendingCount
        return "Loading \(count) screenshot\(count == 1 ? "" : "s")…"
    }

    private var historyBubble: some View {
        Button {
            viewModel.isPresentingHistory = true
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 18.0, weight: .medium))
                .foregroundStyle(.colorTextPrimary)
                .frame(
                    width: DesignConstants.Spacing.step12x,
                    height: DesignConstants.Spacing.step12x
                )
        }
        .clipShape(.circle)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("History")
        .accessibilityIdentifier("doc-history")
    }

    private var inputCapsule: some View {
        MessagesInputView(
            displayName: .constant(""),
            emptyDisplayNamePlaceholder: "",
            messagePlaceholder: composerPlaceholder,
            messageText: messageText,
            pendingMediaAttachments: pendingMediaAttachments,
            pendingInviteConvoName: .constant(""),
            pendingInviteImage: .constant(nil),
            sendButtonEnabled: canSend,
            focusState: $focusState,
            messagesTextFieldEnabled: isReady && !isSending,
            onSendMessage: send,
            onClearInvite: {},
            onClearMediaAttachment: { id in
                viewModel.removePendingPhoto(id: id, in: scope)
            },
            fileAttachmentPreview: { _ in EmptyView() },
            agentShareChip: { EmptyView() },
            attachmentsButton: { photoPicker }
        )
        .opacity(isReady ? 1.0 : 0.4)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(.rect(cornerRadius: 26.0))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26.0))
        .glassEffectID("doc-input-\(scope.identifier)", in: namespace)
        .glassEffectTransition(.matchedGeometry)
    }

    private var photoPicker: some View {
        PhotosPicker(
            selection: $selectedPhotos,
            maxSelectionCount: DocScreenshotSelectionPolicy.maximumSelectionCount,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Image(systemName: "plus")
                .font(.system(size: 18.0, weight: .medium))
                .foregroundStyle(Color.colorTextPrimary)
                .frame(width: 32.0, height: 32.0)
        }
        .disabled(!isReady || isSending || photoLoadGate.isLoading)
        .accessibilityLabel("Choose screenshots")
        .accessibilityIdentifier("doc-photo-picker")
    }

    private var sendErrorIdentifier: String {
        switch scope {
        case .home: "doc-send-error"
        case .room: "doc-room-send-error"
        }
    }

    private var composerPlaceholder: String {
        if isReady { return messagePlaceholder }
        if viewModel.agentStartupErrorMessage != nil { return "Doc needs attention" }
        return "Preparing Doc…"
    }

    private func send() {
        guard canSend else { return }
        isSending = true
        didFail = false
        Task { @MainActor in
            let sent = await viewModel.sendComposerDraft(in: scope)
            didFail = !sent
            isSending = false
            if sent {
                focusState = .message
            }
        }
    }

    private func load(_ photos: [PhotosPickerItem]) {
        guard !photos.isEmpty else { return }
        photoLoadGate.begin(count: photos.count)
        selectedPhotos = []
        Task { @MainActor in
            for photo in photos {
                if let data = try? await photo.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    viewModel.addPendingPhoto(image, in: scope)
                }
                photoLoadGate.finishOne()
            }
        }
    }
}

private extension DocComposerScope {
    var identifier: String {
        switch self {
        case .home: "home"
        case .room(let docId): "room-\(docId)"
        }
    }
}
