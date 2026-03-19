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
    var composerLinkPreview: LinkPreview?
    var pendingInviteCode: String?
    let sendButtonEnabled: Bool
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let animateAvatarForQuickname: Bool
    let messagesTextFieldEnabled: Bool
    private let focused: MessagesViewInputFocus = .message
    let onProfilePhotoTap: () -> Void
    let onSendMessage: () -> Void
    let onClearInvite: () -> Void
    var onClearLinkPreview: (() -> Void)?

    private let attachmentPreviewSize: CGFloat = 80.0
    @State private var isPoofing: Bool = false
    @State private var isPoofingInvite: Bool = false

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

    private var hasAttachments: Bool {
        selectedAttachmentImage != nil || pendingInviteCode != nil || composerLinkPreview != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasAttachments {
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
                    .padding(.leading, DesignConstants.Spacing.step2x)
                    .padding(.trailing, DesignConstants.Spacing.step3x)
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
                if pendingInviteCode != nil {
                    inviteAttachmentPreview
                }
                if let composerLinkPreview {
                    linkPreviewAttachment(preview: composerLinkPreview)
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .padding(.bottom, DesignConstants.Spacing.step2x)
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
                .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
                .scaleEffect(isPoofing ? 1.3 : 1.0)
                .blur(radius: isPoofing ? 12.0 : 0.0)
                .opacity(isPoofing ? 0.0 : 1.0)
                .accessibilityLabel("Attachment preview")
                .accessibilityIdentifier("attachment-preview-image")

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isPoofing = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    selectedAttachmentImage = nil
                    isPoofing = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.0, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20.0, height: 20.0)
                    .background(.black)
                    .clipShape(.circle)
                    .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1.0))
            }
            .opacity(isPoofing ? 0.0 : 1.0)
            .padding(.top, DesignConstants.Spacing.step2x)
            .padding(.trailing, DesignConstants.Spacing.step2x)
            .accessibilityLabel("Remove attachment")
            .accessibilityIdentifier("remove-attachment-button")
        }
    }

    @ViewBuilder
    private var inviteAttachmentPreview: some View {
        let invitePreviewWidth: CGFloat = 90
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                ZStack {
                    Image("convosOrangeIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.colorTextPrimaryInverted)
                        .frame(width: 22, height: 22)
                }
                .frame(width: invitePreviewWidth, height: attachmentPreviewSize * 0.6)
                .background(.colorFillPrimary)

                Text("Invite")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: attachmentPreviewSize * 0.4)
                    .background(.colorFillMinimal)
            }
            .frame(width: invitePreviewWidth, height: attachmentPreviewSize)
            .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
            .scaleEffect(isPoofingInvite ? 1.3 : 1.0)
            .blur(radius: isPoofingInvite ? 12.0 : 0.0)
            .opacity(isPoofingInvite ? 0.0 : 1.0)
            .accessibilityLabel("Invite attachment preview")
            .accessibilityIdentifier("invite-attachment-preview")

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isPoofingInvite = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    onClearInvite()
                    isPoofingInvite = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.0, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20.0, height: 20.0)
                    .background(.black)
                    .clipShape(.circle)
                    .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1.0))
            }
            .opacity(isPoofingInvite ? 0.0 : 1.0)
            .padding(.top, DesignConstants.Spacing.step2x)
            .padding(.trailing, DesignConstants.Spacing.step2x)
            .accessibilityLabel("Remove invite")
            .accessibilityIdentifier("remove-invite-button")
        }
    }

    @State private var isPoofingLinkPreview: Bool = false

    @ViewBuilder
    private func linkPreviewAttachment(preview: LinkPreview) -> some View {
        ZStack(alignment: .topTrailing) {
            ComposerLinkPreviewCard(preview: preview)
                .frame(height: attachmentPreviewSize)
                .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
                .scaleEffect(isPoofingLinkPreview ? 1.3 : 1.0)
                .blur(radius: isPoofingLinkPreview ? 12.0 : 0.0)
                .opacity(isPoofingLinkPreview ? 0.0 : 1.0)
                .accessibilityLabel("Link preview")
                .accessibilityIdentifier("link-preview-attachment")

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isPoofingLinkPreview = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    onClearLinkPreview?()
                    isPoofingLinkPreview = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.0, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20.0, height: 20.0)
                    .background(.black)
                    .clipShape(.circle)
                    .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1.0))
            }
            .opacity(isPoofingLinkPreview ? 0.0 : 1.0)
            .padding(.top, DesignConstants.Spacing.step2x)
            .padding(.trailing, DesignConstants.Spacing.step2x)
            .accessibilityLabel("Remove link preview")
            .accessibilityIdentifier("remove-link-preview-button")
        }
    }
}

private struct ComposerLinkPreviewCard: View {
    let preview: LinkPreview

    @State private var ogTitle: String?
    @State private var ogSiteName: String?
    @State private var cachedImage: UIImage?
    @State private var hasFetchedMetadata: Bool = false

    private var displayTitle: String {
        ogTitle ?? preview.title ?? preview.displayHost
    }

    private var displaySubtitle: String {
        let siteName = ogSiteName ?? preview.siteName
        if let siteName, siteName.lowercased() != displayTitle.lowercased() {
            return siteName
        }
        return preview.displayHost
    }

    private let previewWidth: CGFloat = 140.0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let image = cachedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "link")
                        .font(.title3)
                        .foregroundStyle(.colorTextSecondary)
                }
            }
            .frame(width: previewWidth, height: 48.0)
            .clipped()
            .background(.colorFillMinimal)

            VStack(alignment: .leading, spacing: 0) {
                Text(displayTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(displaySubtitle)
                    .font(.caption2)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .frame(width: previewWidth, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(.colorLinkBackground)
        }
        .task {
            await fetchMetadata()
        }
    }

    private func fetchMetadata() async {
        guard !hasFetchedMetadata else { return }
        let metadata = await OpenGraphService.shared.fetchMetadata(for: preview.url)
        if let metadata {
            ogTitle = metadata.title
            ogSiteName = metadata.siteName
            if let imageURLString = metadata.imageURL ?? preview.imageURL,
               let imageURL = URL(string: imageURLString) {
                await loadImage(from: imageURL)
            }
        } else if let imageURLString = preview.imageURL,
                  let imageURL = URL(string: imageURLString) {
            await loadImage(from: imageURL)
        }
        hasFetchedMetadata = true
    }

    private func loadImage(from url: URL) async {
        let cacheKey = url.absoluteString
        if let cached = await ImageCache.shared.imageAsync(for: cacheKey) {
            cachedImage = cached
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard OpenGraphService.isValidImageData(data) else { return }
            if let image = UIImage(data: data),
               OpenGraphService.isValidImageSize(width: image.size.width, height: image.size.height) {
                ImageCache.shared.cacheImage(image, for: cacheKey, storageTier: .cache)
                cachedImage = image
            }
        } catch {
            Log.error("Failed to load composer link preview image")
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
    @Previewable @State var pendingInviteCodePreview: String? = "test-invite-code"
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
            pendingInviteCode: pendingInviteCodePreview,
            sendButtonEnabled: sendButtonEnabled,
            focusState: $focusState,
            animateAvatarForQuickname: animateAvatarForQuickname,
            messagesTextFieldEnabled: true,
            onProfilePhotoTap: {},
            onSendMessage: {},
            onClearInvite: { pendingInviteCodePreview = nil }
        )
        .padding(DesignConstants.Spacing.step2x)
    }
}
