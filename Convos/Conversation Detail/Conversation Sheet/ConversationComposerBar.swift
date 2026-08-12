import ConvosComposer
import ConvosCore
import SwiftUI

/// The composer hosted by the conversation sheet, bound to a
/// `ConversationViewModel`: the group chat's on the Group tab, the agent
/// DM's on the Agent tab. Mirrors the `MessagesBottomBar` construction the
/// transcript's `MessagesView` used to own before the composer moved into
/// the floating sheet (`hostsBottomBar: false` suppresses it there).
///
/// The transcript and the composer now live in separate trees, so the
/// send-driven scroll-to-bottom arrives through `scrollToBottom`, bridged
/// from `MessagesView.onScrollToBottomAvailable`.
struct ConversationComposerBar<ExtraBarContent: View>: View {
    @Bindable var viewModel: ConversationViewModel
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    let messagesTextFieldEnabled: Bool
    var messagePlaceholder: String = "Chat"
    /// True on the Group tab: the pending-invite side-convo fields, the
    /// explode-duration control, and the debug injector belong to the group
    /// composer only.
    var isGroupComposer: Bool = true
    /// Scrolls the paired transcript to the bottom; invoked on send.
    var scrollToBottom: (() -> Void)?
    var onDebugAttachmentTap: (() -> Void)?
    /// Extra rows above the composer, e.g. the onboarding view and the
    /// capability-approved toast on the Group tab.
    @ViewBuilder let extraBarContent: () -> ExtraBarContent

    @State private var isPhotoPickerPresented: Bool = false

    var body: some View {
        MessagesBottomBar(
            profile: viewModel.profile,
            displayName: $viewModel.myProfileViewModel.editingDisplayName,
            messageText: $viewModel.messageText,
            pendingMediaAttachments: viewModel.isAwaitingBuilderBundleSend ? [] : viewModel.pendingMediaAttachments,
            composerLinkPreview: viewModel.pastedLinkPreview,
            pendingInviteURL: viewModel.pendingInvite?.fullURL,
            pendingInviteIsEditable: !isGroupComposer || viewModel.pendingInvite?.linkedConversationId != nil,
            pendingInviteEmoji: isGroupComposer ? viewModel.conversation.conversationEmoji : nil,
            pendingInviteConvoName: $viewModel.pendingInviteConvoName,
            pendingInviteImage: $viewModel.pendingInviteImage,
            pendingInviteExplodeDuration: isGroupComposer ? viewModel.pendingInvite?.explodeDuration : nil,
            onSetInviteExplodeDuration: isGroupComposer ? { duration in viewModel.setInviteExplodeDuration(duration) } : nil,
            onInviteConvoNameEditingEnded: isGroupComposer ? { name in
                viewModel.updateLinkedConversationName(name)
                focusCoordinator.endEditing(for: .sideConvoName, context: .quickEditor)
            } : nil,
            isShowingAgentShareChip: viewModel.pendingAgentShare != nil,
            sendButtonEnabled: viewModel.sendButtonEnabled,
            profileImage: $viewModel.myProfileViewModel.profileImage,
            isPhotoPickerPresented: $isPhotoPickerPresented,
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            messagesTextFieldEnabled: messagesTextFieldEnabled,
            messagePlaceholder: messagePlaceholder,
            onSendMessage: {
                scrollToBottom?()
                viewModel.onSendMessage(focusCoordinator: focusCoordinator)
            },
            onClearInvite: viewModel.clearPendingInvite,
            onClearLinkPreview: { viewModel.pastedLinkPreview = nil },
            onClearMediaAttachment: viewModel.removeMediaAttachment(id:),
            onDisplayNameEndedEditing: {
                viewModel.onDisplayNameEndedEditing(focusCoordinator: focusCoordinator, context: .quickEditor)
            },
            onPhotoSelected: viewModel.addPhotoAttachment(_:),
            onVideoSelected: viewModel.addVideoAttachment(url:),
            onFileSelected: viewModel.addFileAttachment(url:filename:mimeType:fileSize:),
            onProfileSettings: viewModel.onProfileSettings,
            onVoiceMemoTap: { viewModel.onVoiceMemoTapped() },
            voiceMemoRecorder: viewModel.voiceMemoRecorder,
            onSendVoiceMemo: { viewModel.sendVoiceMemo() },
            onDebugAttachmentTap: onDebugAttachmentTap,
            onBaseHeightChanged: { _ in
                // The sheet measures its own full card height; the bar's base
                // height is not needed separately.
            },
            bottomBarContent: {
                extraBarContent()
                if let replyingToMessage = viewModel.replyingToMessage {
                    ReplyComposerBar(
                        message: replyingToMessage,
                        audioTranscriptText: viewModel.replyingToAudioTranscriptText,
                        onDismiss: viewModel.cancelReply
                    )
                    // The bar renders outside the transcript's tree, so inject
                    // the resolver directly (same reason the context-menu
                    // overlay does).
                    .environment(\.agentShareResolver, viewModel.agentShareResolver)
                    // The composer block carries no top inset of its own, so
                    // the reply bar supplies the separation.
                    .padding(.bottom, DesignConstants.Spacing.step2x)
                }
            },
            quickEditView: { placeholderText, isImagePickerPresented in
                quickEditView(placeholderText: placeholderText, isImagePickerPresented: isImagePickerPresented)
            },
            fileAttachmentPreview: { file in
                ComposerFileAttachmentPreview(file: file)
            },
            agentShareChip: {
                AgentContactCardChip(
                    displayName: viewModel.pendingAgentShare?.resolved?.displayName ?? "Agent",
                    emoji: viewModel.pendingAgentShare?.resolved?.emoji,
                    summary: viewModel.pendingAgentShare?.resolved?.descriptionText,
                    onRemove: { viewModel.clearPendingAgentShare() }
                )
            }
        )
    }

    @MainActor @ViewBuilder
    private func quickEditView(placeholderText: String, isImagePickerPresented: Binding<Bool>) -> some View {
        QuickEditView(
            placeholderText: placeholderText,
            text: $viewModel.myProfileViewModel.editingDisplayName,
            image: $viewModel.myProfileViewModel.profileImage,
            isImagePickerPresented: isImagePickerPresented,
            imageAssetIdentifier: Binding(
                get: { ProfileSettingsViewModel.shared.profileImageAssetIdentifier },
                set: { ProfileSettingsViewModel.shared.profileImageAssetIdentifier = $0 }
            ),
            focusState: $focusState,
            focused: .displayName,
            settingsSymbolName: "lanyardcard.fill",
            showsSettingsButton: false,
            onSubmit: {
                viewModel.onDisplayNameEndedEditing(focusCoordinator: focusCoordinator, context: .quickEditor)
            },
            onSettings: viewModel.onProfileSettings
        )
    }
}
