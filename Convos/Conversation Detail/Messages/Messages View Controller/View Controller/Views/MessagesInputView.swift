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
    @State private var isPoofing: Bool = false

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
                .accessibilityLabel("Edit your profile")
                .accessibilityIdentifier("profile-avatar-button")

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
                    .accessibilityLabel("Message input")
                    .accessibilityIdentifier("message-text-field")
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
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("send-message-button")
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
            .padding(.horizontal, DesignConstants.Spacing.step2x * 2)
            .padding(.vertical, DesignConstants.Spacing.step2x)
        }
        .scrollClipDisabled()
        .padding(.horizontal, -DesignConstants.Spacing.step2x)
    }

    @ViewBuilder
    private func attachmentPreview(image: UIImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: attachmentPreviewSize, height: attachmentPreviewSize)
                .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step3x))
                .scaleEffect(isPoofing ? 1.3 : 1.0)
                .blur(radius: isPoofing ? 12.0 : 0.0)
                .opacity(isPoofing ? 0.0 : 1.0)

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isPoofing = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    selectedAttachmentImage = nil
                    isPoofing = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20.0))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .opacity(isPoofing ? 0.0 : 1.0)
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
