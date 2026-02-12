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
    let sendButtonEnabled: Bool
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let animateAvatarForQuickname: Bool
    let messagesTextFieldEnabled: Bool
    private let focused: MessagesViewInputFocus = .message
    let onProfilePhotoTap: () -> Void
    let onSendMessage: () -> Void

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
        .padding(DesignConstants.Spacing.step2x)
        .frame(alignment: .bottom)
    }
}

#Preview {
    @Previewable @State var profile: Profile = .mock()
    @Previewable @State var displayName: String = "Andrew"
    @Previewable @State var messageText: String = ""
    @Previewable @State var sendButtonEnabled: Bool = false
    @Previewable @State var profileImage: UIImage?
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
