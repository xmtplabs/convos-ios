import ConvosCore
import PhotosUI
import SwiftUI
import UIKit

struct MessagesInputView: View {
    let profile: Profile
    @Binding var profileImage: UIImage?
    @Binding var displayName: String
    let emptyDisplayNamePlaceholder: String
    @Binding var messageText: String
    @Binding var selectedAttachmentImage: UIImage?
    let sendButtonEnabled: Bool
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let animateAvatarForQuickname: Bool
    let messagesTextFieldEnabled: Bool
    private let focused: MessagesViewInputFocus = .message
    let onProfilePhotoTap: () -> Void
    let onSendMessage: () -> Void

    private let attachmentPreviewSize: CGFloat = 80.0

    static var defaultHeight: CGFloat {
        32.0
    }

    private var sendButtonSize: CGFloat {
        Self.defaultHeight
    }

    @State private var avatarScale: CGFloat = 1.0

    private func updateAnimation() {
        if animateAvatarForQuickname {
            withAnimation(Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                avatarScale = 1.2
            }
        } else {
            withAnimation {
                avatarScale = 1.0
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selectedAttachmentImage != nil {
                attachmentPreviewArea
            }

            HStack(alignment: .bottom, spacing: 0) {
                Button {
                    onProfilePhotoTap()
                } label: {
                    ProfileAvatarView(
                        profile: profile,
                        profileImage: profileImage,
                        useSystemPlaceholder: animateAvatarForQuickname
                    )
                }
                .frame(width: sendButtonSize, height: sendButtonSize)
                .frame(alignment: .bottomLeading)
                .scaleEffect(avatarScale)
                .task(id: animateAvatarForQuickname) {
                    updateAnimation()
                }
                .hoverEffect(.lift)

                Group {
                    TextField(
                        "Chat as \(profile.displayName)",
                        text: $messageText,
                        axis: .vertical
                    )
                    .focused($focusState, equals: focused)
                    .font(.callout)
                    .foregroundStyle(.colorTextPrimary)
                    .tint(.colorTextPrimary)
                    .frame(minHeight: Self.defaultHeight, maxHeight: 170.0, alignment: .center)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .disabled(!messagesTextFieldEnabled)
                }
                .onSubmit {
                    onSendMessage()
                    focusState = .message
                }
                .frame(maxHeight: .infinity, alignment: .center)

                Button {
                    onSendMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .symbolEffect(.bounce.up.byLayer, options: .nonRepeating)
                        .frame(width: sendButtonSize, height: sendButtonSize, alignment: .center)
                        .tint(sendButtonEnabled ? .colorTextPrimaryInverted : .colorTextPrimary)
                        .font(.callout.weight(.medium))
                }
                .background(sendButtonEnabled ? .colorFillPrimary : .colorFillMinimal)
                .mask(Circle())
                .frame(width: sendButtonSize, height: sendButtonSize, alignment: .bottomLeading)
                .hoverEffect(.lift)
                .hoverEffectDisabled(!sendButtonEnabled)
                .disabled(!sendButtonEnabled)
            }
        }
        .padding(DesignConstants.Spacing.step2x)
        .frame(alignment: .bottom)
    }

    @ViewBuilder
    private var attachmentPreviewArea: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                if let image = selectedAttachmentImage {
                    attachmentPreview(image: image)
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .padding(.top, DesignConstants.Spacing.step2x)
            .padding(.bottom, DesignConstants.Spacing.step2x)
        }
    }

    @ViewBuilder
    private func attachmentPreview(image: UIImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: attachmentPreviewSize, height: attachmentPreviewSize)
                .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step3x))

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedAttachmentImage = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20.0))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6.0, y: -6.0)
        }
    }
}

#Preview {
    @Previewable @State var profile: Profile = .mock()
    @Previewable @State var displayName: String = "Andrew"
    @Previewable @State var messageText: String = ""
    @Previewable @State var sendButtonEnabled: Bool = false
    @Previewable @State var profileImage: UIImage?
    @Previewable @State var selectedAttachmentImage: UIImage?
    @Previewable @State var animateAvatarForQuickname: Bool = false
    @Previewable @FocusState var focusState: MessagesViewInputFocus?

    VStack {
        Spacer()
        Button {
            withAnimation {
                animateAvatarForQuickname.toggle()
            }
        } label: {
            Text("Toggle Quickname Setup")
        }
        Spacer()
    }
    .safeAreaBar(edge: .bottom) {
        MessagesInputView(
            profile: profile,
            profileImage: $profileImage,
            displayName: $displayName,
            emptyDisplayNamePlaceholder: "Somebody",
            messageText: $messageText,
            selectedAttachmentImage: $selectedAttachmentImage,
            sendButtonEnabled: sendButtonEnabled,
            focusState: $focusState,
            animateAvatarForQuickname: animateAvatarForQuickname,
            messagesTextFieldEnabled: true,
            onProfilePhotoTap: {},
            onSendMessage: {}
        )
        .padding(DesignConstants.Spacing.step2x)
    }
}
