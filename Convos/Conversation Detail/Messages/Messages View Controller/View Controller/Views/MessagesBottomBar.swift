import ConvosCore
import SwiftUI

enum MessagesViewInputFocus: Hashable {
    case message, displayName, conversationName
}

struct MessagesBottomBar: View {
    let profile: Profile
    @Binding var displayName: String
    let emptyDisplayNamePlaceholder: String = "Somebody"
    @Binding var messageText: String
    @Binding var sendButtonEnabled: Bool
    @Binding var profileImage: UIImage?
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    let animateAvatarForQuickname: Bool
    let messagesTextFieldEnabled: Bool
    let onProfilePhotoTap: () -> Void
    let onSendMessage: () -> Void
    let onDisplayNameEndedEditing: () -> Void
    let onProfileSettings: () -> Void

    @State private var isExpanded: Bool = false
    @Namespace private var namespace: Namespace.ID

    var body: some View {
        GlassEffectContainer {
            ZStack {
                if !isExpanded {
                    MessagesInputView(
                        profile: profile,
                        profileImage: $profileImage,
                        displayName: $displayName,
                        emptyDisplayNamePlaceholder: emptyDisplayNamePlaceholder,
                        messageText: $messageText,
                        sendButtonEnabled: $sendButtonEnabled,
                        focusState: $focusState,
                        animateAvatarForQuickname: animateAvatarForQuickname,
                        messagesTextFieldEnabled: messagesTextFieldEnabled,
                        onProfilePhotoTap: onProfilePhotoTap,
                        onSendMessage: onSendMessage
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .clipShape(.rect(cornerRadius: 26.0))
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26.0))
                    .glassEffectID("input", in: namespace)
                    .glassEffectTransition(.matchedGeometry)
                }

                if isExpanded {
                    QuickEditView(
                        placeholderText: "\(emptyDisplayNamePlaceholder)...",
                        text: $displayName,
                        image: $profileImage,
                        focusState: $focusState,
                        focused: .displayName,
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
        }
        .padding(.horizontal, 10.0)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .onChange(of: focusCoordinator.currentFocus) { _, newValue in
            withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
                isExpanded = newValue == .displayName ? true : false
            }
        }
    }
}

#Preview {
    @Previewable @State var profile: Profile = .mock()
    @Previewable @State var profileName: String = ""
    @Previewable @State var messageText: String = ""
    @Previewable @State var sendButtonEnabled: Bool = false
    @Previewable @State var profileImage: UIImage?
    @Previewable var animateAvatarForQuickname: Bool = false
    @Previewable @FocusState var focusState: MessagesViewInputFocus?
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    @Previewable @State var bottomBarHeight: CGFloat = 0.0

    Group {
        MessagesViewRepresentable(
            conversation: .mock(),
            messages: [],
            invite: .mock(),
            scrollViewWillBeginDragging: {},
            hasLoadedAllMessages: true,
            onTapAvatar: { _ in },
            onLoadPreviousMessages: {},
            bottomBarHeight: bottomBarHeight
        )
        .ignoresSafeArea()
    }
    .safeAreaBar(edge: .bottom) {
        VStack(spacing: 0.0) {
            MessagesBottomBar(
                profile: profile,
                displayName: $profileName,
                messageText: $messageText,
                sendButtonEnabled: $sendButtonEnabled,
                profileImage: $profileImage,
                focusState: $focusState,
                focusCoordinator: focusCoordinator,
                animateAvatarForQuickname: animateAvatarForQuickname,
                messagesTextFieldEnabled: true,
                onProfilePhotoTap: {
                    focusCoordinator.moveFocus(to: .displayName)
                },
                onSendMessage: {},
                onDisplayNameEndedEditing: {
                    focusCoordinator.endEditing(for: .displayName)
                },
                onProfileSettings: {}
            )
            .background(HeightReader())
            .onPreferenceChange(HeightPreferenceKey.self) { height in
                bottomBarHeight = height
            }
        }
        .background(HeightReader())
        .onPreferenceChange(HeightPreferenceKey.self) { height in
            bottomBarHeight = height
        }
    }
}
