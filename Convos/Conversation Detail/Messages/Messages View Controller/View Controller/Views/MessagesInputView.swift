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
    var isVideoAttachment: Bool = false
    var composerLinkPreview: LinkPreview?
    var pendingInviteURL: String?
    var pendingInviteEmoji: String?
    @Binding var pendingInviteConvoName: String
    @Binding var pendingInviteImage: UIImage?
    var pendingInviteExplodeDuration: ExplodeDuration?
    var onSetInviteExplodeDuration: ((ExplodeDuration?) -> Void)?
    var onInviteConvoNameEditingEnded: ((String) -> Void)?
    let sendButtonEnabled: Bool
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let animateAvatarForQuickname: Bool
    let messagesTextFieldEnabled: Bool
    let isCollapsed: Bool
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
        selectedAttachmentImage != nil || pendingInviteURL != nil || composerLinkPreview != nil
    }

    private var avatarButton: some View {
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
    }

    private var sendButton: some View {
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

    private var messageTextField: some View {
        Group {
            TextField(
                isCollapsed ? "Chat" : "Chat as \(profile.displayName)",
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasAttachments {
                attachmentPreviewArea
            }

            HStack(alignment: .bottom, spacing: 0) {
                avatarButton
                messageTextField
                sendButton
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
                if let pendingInviteURL {
                    inviteAttachmentPreview(url: pendingInviteURL)
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
                .accessibilityLabel(isVideoAttachment ? "Video attachment preview" : "Attachment preview")
                .accessibilityIdentifier("attachment-preview-image")
                .overlay(alignment: .bottomLeading) {
                    if isVideoAttachment {
                        Image(systemName: "video.fill")
                            .font(.system(size: 16.0, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                            .padding(.bottom, DesignConstants.Spacing.step2x)
                            .padding(.leading, DesignConstants.Spacing.step2x)
                            .accessibilityHidden(true)
                    }
                }

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
    private func inviteAttachmentPreview(url: String) -> some View {
        ZStack(alignment: .topTrailing) {
            ComposerSideConvoCard(
                inviteURL: url,
                conversationEmoji: pendingInviteEmoji,
                convoName: $pendingInviteConvoName,
                convoImage: $pendingInviteImage,
                explodeDuration: pendingInviteExplodeDuration,
                focusState: $focusState,
                onSetExplodeDuration: onSetInviteExplodeDuration,
                onNameEditingEnded: onInviteConvoNameEditingEnded
            )
            .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
            .scaleEffect(isPoofingInvite ? 1.3 : 1.0)
            .blur(radius: isPoofingInvite ? 12.0 : 0.0)
            .opacity(isPoofingInvite ? 0.0 : 1.0)
            .accessibilityElement(children: .contain)
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
    @State private var imageAspectRatio: CGFloat?
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

    private var clampedAspectRatio: CGFloat {
        let ratio = imageAspectRatio ?? preview.imageAspectRatio ?? 1.91
        return min(max(ratio, 0.75), 2.0)
    }

    private let previewWidth: CGFloat = 200.0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let image = cachedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blendMode(.multiply)
                } else if hasFetchedMetadata {
                    EmptyView()
                } else {
                    Image(systemName: "link")
                        .font(.title3)
                        .foregroundStyle(.colorTextSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 80.0)
                }
            }
            .frame(maxWidth: .infinity)
            .modifier(ComposerImageAreaModifier(hasKnownRatio: cachedImage != nil || preview.imageAspectRatio != nil, aspectRatio: clampedAspectRatio))
            .clipped()
            .background(.colorBackgroundMedia)

            VStack(alignment: .leading, spacing: 2.0) {
                Text(displayTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .frame(width: previewWidth, alignment: .leading)
            .background(.colorFillSubtle)
        }
        .frame(width: previewWidth)
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
            if let w = metadata.imageWidth, let h = metadata.imageHeight, w > 0, h > 0 {
                imageAspectRatio = CGFloat(w) / CGFloat(h)
            }
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
            imageAspectRatio = cached.size.width / cached.size.height
            return
        }
        if let image = await OpenGraphService.shared.loadImage(from: url) {
            ImageCache.shared.cacheImage(image, for: cacheKey, storageTier: .cache)
            cachedImage = image
            imageAspectRatio = image.size.width / image.size.height
        }
    }
}

private struct ComposerImageAreaModifier: ViewModifier {
    let hasKnownRatio: Bool
    let aspectRatio: CGFloat

    func body(content: Content) -> some View {
        if hasKnownRatio {
            content.aspectRatio(aspectRatio, contentMode: .fit)
        } else {
            content
        }
    }
}

private struct ComposerSideConvoCard: View {
    let inviteURL: String
    var conversationEmoji: String?
    @Binding var convoName: String
    @Binding var convoImage: UIImage?
    var explodeDuration: ExplodeDuration?
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    var onSetExplodeDuration: ((ExplodeDuration?) -> Void)?
    var onNameEditingEnded: ((String) -> Void)?

    @State private var isPhotoPickerPresented: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    private let cardWidth: CGFloat = 200.0

    private var invite: MessageInvite? {
        MessageInvite.from(text: inviteURL)
    }

    private var resolvedEmoji: String? {
        if let emoji = invite?.emoji, !emoji.isEmpty { return emoji }
        if let emoji = conversationEmoji, !emoji.isEmpty { return emoji }
        return nil
    }

    private var explodeDurationLabel: String {
        guard let explodeDuration else { return "Not exploding" }
        return "Explodes in \(explodeDuration.shortLabel)"
    }

    var body: some View {
        VStack(spacing: 0) {
            emojiArea
            VStack(spacing: DesignConstants.Spacing.step2x) {
                nameField
                explodeButton
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.vertical, DesignConstants.Spacing.step3x)
        }
        .frame(width: cardWidth)
        .background(.colorFillSubtle)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("side-convo-card")
    }

    @ViewBuilder
    private var emojiArea: some View {
        emojiAreaContent
            .onTapGesture {
                isPhotoPickerPresented = true
            }
            .photosPicker(isPresented: $isPhotoPickerPresented, selection: $selectedPhotoItem, matching: .images)
            .onChange(of: selectedPhotoItem) {
                guard let selectedPhotoItem else { return }
                Task { @MainActor in
                    guard let data = try? await selectedPhotoItem.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    convoImage = image
                    self.selectedPhotoItem = nil
                }
            }
    }

    @ViewBuilder
    private var emojiAreaContent: some View {
        ZStack {
            if let convoImage {
                Image(uiImage: convoImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let emoji = resolvedEmoji {
                Text(emoji)
                    .font(.system(size: 120))
            } else {
                Image("convosOrangeIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .frame(width: 48, height: 48)
            }
        }
        .frame(width: cardWidth, height: cardWidth)
        .clipped()
        .background(.colorFillMinimal)
        .accessibilityLabel(convoImage != nil ? "Side convo image" : (resolvedEmoji.map { "Side convo emoji \($0)" } ?? "Side convo placeholder"))
        .accessibilityIdentifier("side-convo-avatar-preview")
    }

    @ViewBuilder
    private var nameField: some View {
        TextField("Convo name", text: $convoName)
            .focused($focusState, equals: .editingSideConvoName)
            .font(.callout)
            .foregroundStyle(.colorTextPrimary)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .background(.colorFillMinimal)
            .clipShape(Capsule())
            .accessibilityIdentifier("side-convo-name-field")
            .onSubmit {
                onNameEditingEnded?(convoName)
            }
    }

    @ViewBuilder
    private var explodeButton: some View {
        Menu {
            Section("Explode messages and members") {
                Button {
                    onSetExplodeDuration?(nil)
                } label: {
                    Text("Never")
                }
                ForEach(ExplodeDuration.allCases, id: \.self) { duration in
                    Button {
                        onSetExplodeDuration?(duration)
                    } label: {
                        Text(duration.label)
                    }
                }
            }
        } label: {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Text(explodeDurationLabel)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .accessibilityIdentifier("side-convo-explode-menu")
    }
}

#Preview {
    @Previewable @State var profile: Profile = .mock()
    @Previewable @State var displayName: String = "Andrew"
    @Previewable @State var messageText: String = ""
    @Previewable @State var sendButtonEnabled: Bool = false
    @Previewable @State var profileImage: UIImage?
    @Previewable @State var selectedAttachmentImage: UIImage?
    @Previewable @State var pendingInviteURLPreview: String? = "https://convos.xyz/invite/test-code"
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
            pendingInviteURL: pendingInviteURLPreview,
            pendingInviteConvoName: .constant(""),
            pendingInviteImage: .constant(nil),
            sendButtonEnabled: sendButtonEnabled,
            focusState: $focusState,
            animateAvatarForQuickname: animateAvatarForQuickname,
            messagesTextFieldEnabled: true,
            isCollapsed: true,
            onProfilePhotoTap: {},
            onSendMessage: {},
            onClearInvite: { pendingInviteURLPreview = nil }
        )
        .padding(DesignConstants.Spacing.step2x)
    }
}

struct ExplodeCountdownBadge: View {
    let duration: ExplodeDuration

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "burst")
                .font(.system(size: 10, weight: .semibold))
            Text(duration.label)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.colorCaution)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.colorCaution.opacity(0.15), in: Capsule())
    }
}
