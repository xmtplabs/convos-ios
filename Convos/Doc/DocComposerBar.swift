import ConvosComposer
import ConvosCore
import PhotosUI
import SwiftUI
import UIKit

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
        return isReady && !isSending && (!cleanText.isEmpty || !pendingPhotos.isEmpty)
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
            messagePlaceholder: isReady ? messagePlaceholder : "Preparing Doc…",
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
        .disabled(!isReady || isSending)
        .accessibilityLabel("Choose screenshots")
        .accessibilityIdentifier("doc-photo-picker")
    }

    private var sendErrorIdentifier: String {
        switch scope {
        case .home: "doc-send-error"
        case .room: "doc-room-send-error"
        }
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
        selectedPhotos = []
        Task { @MainActor in
            for photo in photos {
                guard let data = try? await photo.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    continue
                }
                viewModel.addPendingPhoto(image, in: scope)
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
