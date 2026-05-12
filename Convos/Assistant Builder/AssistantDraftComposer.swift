import ConvosCore
import SwiftUI

struct AssistantDraftComposer: View {
    @Bindable var viewModel: AssistantBuilderViewModel
    var focusState: FocusState<MessagesViewInputFocus?>.Binding
    let onMakeTap: () -> Void

    @State private var isPhotoPickerPresented: Bool = false
    @State private var isCameraPresented: Bool = false

    private var makeButtonEnabled: Bool {
        viewModel.isMakeEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            textField
            if !viewModel.pendingMediaAttachments.isEmpty {
                attachmentsRow
            }
            bottomRow
        }
        .padding(DesignConstants.Spacing.step4x)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.colorBackgroundRaised, in: RoundedRectangle(cornerRadius: 24))
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .onTapGesture {
            focusState.wrappedValue = .message
        }
        .opacity(viewModel.isCommitting ? 0 : 1)
        .animation(.easeOut(duration: 0.18), value: viewModel.isCommitting)
    }

    private var textField: some View {
        TextField(
            "Make a new little agent",
            text: $viewModel.composerText,
            axis: .vertical
        )
        .focused(focusState, equals: .message)
        .font(.body)
        .foregroundStyle(.colorTextPrimary)
        .tint(.colorTextPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel("Assistant prompt")
        .accessibilityIdentifier("assistant-composer-text-field")
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                ForEach(viewModel.pendingMediaAttachments) { attachment in
                    PendingMediaAttachmentChip(attachment: attachment) { id in
                        viewModel.removeAttachment(id: id)
                    }
                }
            }
        }
        .scrollClipDisabled()
    }

    private var bottomRow: some View {
        HStack(alignment: .center, spacing: DesignConstants.Spacing.step2x) {
            MessagesMediaButtonsView(
                isPhotoPickerPresented: $isPhotoPickerPresented,
                isCameraPresented: $isCameraPresented,
                onVoiceMemoTap: {},
                onFilePickerTap: {},
                onConvosAction: {},
                showsSideConvoButton: false,
                buttonSpacing: DesignConstants.Spacing.step5x
            )
            Spacer(minLength: 0)
            makeButton
        }
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
        .accessibilityLabel("Make assistant")
        .accessibilityIdentifier("assistant-make-button")
    }
}

struct PendingMediaAttachmentChip: View {
    let attachment: PendingMediaAttachment
    let onClear: (UUID) -> Void

    private let chipSize: CGFloat = 80.0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            chipContent
            removeButton
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
        .accessibilityIdentifier("assistant-attachment-preview")
    }

    @ViewBuilder
    private func fileChip(file: PendingFileAttachment) -> some View {
        FileAttachmentRow(
            filename: file.filename,
            mimeType: file.mimeType,
            fileSize: file.fileSize
        )
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .frame(maxWidth: 240.0)
        .background(.colorFillSubtle)
        .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant-file-attachment-preview")
    }

    private var removeButton: some View {
        Button {
            onClear(attachment.id)
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
        .accessibilityIdentifier("remove-assistant-attachment-button")
    }
}

#Preview {
    @Previewable @State var viewModel: AssistantBuilderViewModel = .init(
        session: ConvosClient.mock().session
    )
    @Previewable @FocusState var focusState: MessagesViewInputFocus?
    AssistantDraftComposer(
        viewModel: viewModel,
        focusState: $focusState,
        onMakeTap: {}
    )
    .padding()
}
