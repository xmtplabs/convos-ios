import ConvosCore
import ConvosLogging
import Photos
import SwiftUI

struct MessageContextMenuOverlay: View {
    @Bindable var state: MessageContextMenuState
    let shouldBlurPhotos: Bool
    let onReaction: (String, String) -> Void
    let onReply: (AnyMessage) -> Void
    let onCopy: (String) -> Void
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void

    @State private var appeared: Bool = false
    @State private var emojiAppeared: [Bool] = []
    @State private var showMoreAppeared: Bool = false
    @State private var drawerExpanded: Bool = true
    @State private var showingEmojiPicker: Bool = false
    @State private var customEmoji: String?
    @State private var selectedEmoji: String?
    @State private var popScale: CGFloat = 1.0
    @State private var blurOverride: Bool?

    private var message: AnyMessage? { state.presentedMessage }

    private var copyableText: String? {
        guard let message else { return nil }
        switch message.base.content {
        case .text(let text): return text
        case .emoji(let text): return text
        case .invite(let invite):
            return "https://\(ConfigManager.shared.associatedDomain)/v2?i=\(invite.inviteSlug)"
        default: return nil
        }
    }

    private var photoAttachment: HydratedAttachment? {
        guard let message else { return nil }
        switch message.base.content {
        case .attachment(let attachment): return attachment
        case .attachments(let attachments): return attachments.first
        default: return nil
        }
    }

    private var shouldBlurPhoto: Bool {
        if let blurOverride { return blurOverride }
        guard let photoAttachment, let message else { return false }
        if photoAttachment.isHiddenByOwner { return true }
        if message.base.sender.isCurrentUser { return false }
        return shouldBlurPhotos && !photoAttachment.isRevealed
    }

    var body: some View {
        if let message = state.presentedMessage {
            GeometryReader { proxy in
                let overlayOrigin = proxy.frame(in: .global).origin
                let screenSize = proxy.size
                let safeTop = proxy.safeAreaInsets.top
                let localBubble = CGRect(
                    x: state.bubbleFrame.origin.x - overlayOrigin.x,
                    y: state.bubbleFrame.origin.y - overlayOrigin.y,
                    width: state.bubbleFrame.width,
                    height: state.bubbleFrame.height
                )
                let isPhoto = photoAttachment != nil
                let endBubble = endBubbleRect(
                    source: localBubble,
                    screenSize: screenSize,
                    safeTop: safeTop,
                    isPhoto: isPhoto
                )
                let activeBubble = appeared ? endBubble : localBubble

                ZStack(alignment: .topLeading) {
                    backgroundDimming

                    // Reactions drawer hidden for now, re-enable after polish
                    // reactionsBar(
                    //     messageId: message.base.id,
                    //     bubbleRect: activeBubble,
                    //     sourceBubble: localBubble
                    // )
                    // .zIndex(1)

                    actionMenu(
                        message: message,
                        bubbleRect: activeBubble
                    )
                    .zIndex(2)

                    bubblePreview(
                        message: message,
                        sourceBubble: localBubble,
                        endBubble: endBubble
                    )
                    .zIndex(3)
                }
            }
            .ignoresSafeArea()
            .onAppear {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                emojiAppeared = Array(repeating: false, count: C.defaultReactions.count)
                withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                    appeared = true
                }
                let totalDelay = C.emojiAppearanceDelayStep * Double(C.defaultReactions.count)
                DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay) {
                    withAnimation {
                        showMoreAppeared = true
                    }
                }
                for index in C.defaultReactions.indices {
                    DispatchQueue.main.asyncAfter(deadline: .now() + C.emojiAppearanceDelayStep * Double(index)) {
                        withAnimation {
                            emojiAppeared[index] = true
                        }
                    }
                }
            }
        }
    }

    // MARK: - Background

    private var backgroundDimming: some View {
        Color.clear
            .background(.ultraThinMaterial)
            .opacity(appeared ? 1.0 : 0.0)
            .animation(.easeOut(duration: 0.18), value: appeared)
            .onTapGesture { dismissMenu() }
            .accessibilityLabel("Dismiss menu")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Reactions Bar

    private func reactionsBar(
        messageId: String,
        bubbleRect: CGRect,
        sourceBubble: CGRect
    ) -> some View {
        let startSize: CGFloat = min(sourceBubble.height, sourceBubble.width)
        let drawerWidth: CGFloat = drawerExpanded ? C.expandedWidth : (selectedEmoji != nil ? C.collapsedWidth : C.compactWidth)
        let currentWidth: CGFloat = appeared ? drawerWidth : startSize
        let currentHeight: CGFloat = appeared ? C.drawerHeight : startSize

        let endY: CGFloat = bubbleRect.minY - C.drawerHeight - C.sectionSpacing
        let endX: CGFloat = state.isOutgoing ? bubbleRect.maxX - drawerWidth : bubbleRect.minX
        let startY: CGFloat = sourceBubble.midY - startSize / 2
        let startX: CGFloat = state.isOutgoing ? sourceBubble.maxX - startSize : sourceBubble.minX
        let barX: CGFloat = appeared ? endX : startX
        let barY: CGFloat = appeared ? endY : startY

        return GlassEffectContainer {
            GeometryReader { reader in
                let readerHeight = max(reader.size.height - C.padding * 2, 0)
                ZStack(alignment: .leading) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(Array(C.defaultReactions.enumerated()), id: \.element) { index, emoji in
                                let didAppear = emojiAppeared.indices.contains(index) && emojiAppeared[index]
                                let action = {
                                    selectReaction(emoji, messageId: messageId)
                                }
                                Button(action: action) {
                                    Text(emoji)
                                        .font(.system(size: C.emojiFontSize))
                                        .padding(C.padding)
                                        .blur(radius: !drawerExpanded ? C.blurRadius : (didAppear ? 0 : C.blurRadius))
                                        .scaleEffect(!drawerExpanded ? 0 : (didAppear ? 1.0 : 0))
                                        .rotationEffect(.degrees(didAppear && drawerExpanded ? 0 : C.emojiRotation))
                                        .opacity(!drawerExpanded ? 0 : 1)
                                        .animation(.spring(response: 0.29, dampingFraction: 0.6), value: didAppear)
                                        .animation(.spring(response: 0.29, dampingFraction: 0.6), value: drawerExpanded)
                                }
                                .disabled(!drawerExpanded)
                                .scaleEffect(selectedEmoji == nil ? 1.0 : 0)
                            }
                        }
                        .padding(.horizontal, C.padding)
                    }
                    .frame(height: reader.size.height)
                    .contentMargins(.trailing, readerHeight, for: .scrollContent)
                    .mask(
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [.black.opacity(0), .black],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: C.padding)
                            Rectangle().fill(.black)
                            LinearGradient(
                                colors: [.black, .black.opacity(0)],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: readerHeight * 0.3)
                            Rectangle().fill(.clear)
                                .frame(width: readerHeight)
                        }
                    )

                    HStack(spacing: 0) {
                        Spacer()

                        ZStack {
                            Text(selectedEmoji ?? customEmoji ?? "")
                                .font(.system(size: C.selectedEmojiFontSize))
                                .frame(width: C.selectedEmojiFrame, height: C.selectedEmojiFrame)
                                .scaleEffect(
                                    popScale * (selectedEmoji != nil || customEmoji != nil ? 1.0 : 0)
                                )
                                .animation(.spring(response: 0.29, dampingFraction: 0.8), value: selectedEmoji ?? customEmoji)
                                .animation(.spring(response: 0.14, dampingFraction: 0.5), value: popScale)

                            Image(systemName: "face.smiling")
                                .font(.system(size: C.faceSmilingFontSize))
                                .tint(.black)
                                .opacity(!drawerExpanded && selectedEmoji == nil && customEmoji == nil && showMoreAppeared ? 0.2 : 0)
                                .blur(radius: !drawerExpanded ? 0 : C.blurRadius)
                                .rotationEffect(.degrees(!drawerExpanded ? 0 : -30))
                                .scaleEffect(!drawerExpanded && selectedEmoji == nil && customEmoji == nil ? 1.0 : 0)
                                .animation(.spring(response: 0.29, dampingFraction: 0.8), value: drawerExpanded)
                        }
                        .frame(width: reader.size.height, height: reader.size.height)

                        let plusAction = {
                            withAnimation(.spring(response: 0.29, dampingFraction: 0.7)) {
                                drawerExpanded.toggle()
                                showingEmojiPicker = !drawerExpanded
                            }
                        }
                        Button(action: plusAction) {
                            Image(systemName: "plus")
                                .font(.system(size: C.plusIconFontSize))
                                .padding(C.padding)
                                .tint(.colorTextSecondary)
                                .offset(x: !showMoreAppeared ? 40 : 0)
                                .opacity(!showMoreAppeared ? 0 : 1)
                                .animation(
                                    .spring(response: 0.29, dampingFraction: 0.7),
                                    value: showMoreAppeared
                                )
                                .rotationEffect(.degrees(!drawerExpanded ? -45 : 0))
                        }
                        .frame(minWidth: readerHeight)
                        .padding(.trailing, C.plusTrailingPadding)
                        .scaleEffect(selectedEmoji == nil ? 1.0 : 0)
                        .animation(.spring(response: 0.29, dampingFraction: 0.8), value: selectedEmoji)
                        .animation(.spring(response: 0.29, dampingFraction: 0.7), value: drawerExpanded)
                    }
                }
                .animation(.spring(response: 0.29, dampingFraction: 0.7), value: drawerExpanded)
            }
            .frame(width: currentWidth, height: currentHeight)
            .clipShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .frame(width: currentWidth, height: currentHeight)
        .offset(x: barX, y: barY)
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: appeared)
        .animation(.spring(response: 0.29, dampingFraction: 0.7), value: drawerExpanded)
        .animation(.spring(response: 0.29, dampingFraction: 0.8), value: selectedEmoji)
        .emojiPicker(
            isPresented: $showingEmojiPicker,
            onPick: { emoji in
                customEmoji = emoji
                selectReaction(emoji, messageId: messageId)
            },
            onDelete: {
                customEmoji = nil
            }
        )
    }

    private func selectReaction(_ emoji: String, messageId: String) {
        selectedEmoji = emoji
        onReaction(emoji, messageId)
        showingEmojiPicker = false

        withAnimation(.spring(response: 0.14, dampingFraction: 0.5)) {
            popScale = 1.2
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            withAnimation(.spring(response: 0.29, dampingFraction: 0.8)) {
                popScale = 1.0
                drawerExpanded = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.44) {
            dismissMenu()
        }
    }

    // MARK: - Bubble Positioning

    private func endBubbleRect(
        source: CGRect,
        screenSize: CGSize,
        safeTop: CGFloat,
        isPhoto: Bool = false
    ) -> CGRect {
        let topInset: CGFloat = safeTop + C.topInset
        let minY: CGFloat = topInset + C.drawerHeight + C.sectionSpacing
        let photoInset: CGFloat = isPhoto ? C.photoHorizontalInset : 0
        var endWidth: CGFloat = source.width - (photoInset * 2)
        var endHeight: CGFloat = isPhoto ? endWidth * (source.height / max(source.width, 1)) : source.height

        let menuHeight: CGFloat = isPhoto ? C.photoMenuEstimatedHeight : C.textMenuEstimatedHeight
        let bottomPadding: CGFloat = C.sectionSpacing + menuHeight + C.verticalBreathingRoom
        let maxContentHeight: CGFloat = screenSize.height - minY - bottomPadding - C.verticalBreathingRoom

        if endHeight > maxContentHeight {
            let scale: CGFloat = maxContentHeight / endHeight
            endWidth *= scale
            endHeight = maxContentHeight
        }

        let availableHeight: CGFloat = screenSize.height - minY - bottomPadding
        let centeredY: CGFloat = minY + (availableHeight - endHeight) / 2
        let desiredY: CGFloat = max(centeredY, minY)
        let finalX: CGFloat = (screenSize.width - endWidth) / 2

        return CGRect(x: finalX, y: desiredY, width: endWidth, height: endHeight)
    }

    // MARK: - Bubble Preview

    @ViewBuilder
    private func bubblePreview(
        message: AnyMessage,
        sourceBubble: CGRect,
        endBubble: CGRect
    ) -> some View {
        let rect = appeared ? endBubble : sourceBubble
        let endScale: CGFloat = min(endBubble.width / max(sourceBubble.width, 1), 1.0)
        let scale: CGFloat = appeared ? endScale : 1.0
        Group {
            switch message.base.content {
            case .text(let text):
                MessageBubble(
                    style: state.bubbleStyle,
                    message: text,
                    isOutgoing: state.isOutgoing,
                    profile: message.base.sender.profile
                )

            case .emoji(let text):
                EmojiBubble(
                    emoji: text,
                    isOutgoing: state.isOutgoing,
                    profile: message.base.sender.profile
                )

            case .attachment(let attachment):
                photoPreview(attachment: attachment, message: message)

            case .attachments(let attachments):
                if let attachment = attachments.first {
                    photoPreview(attachment: attachment, message: message)
                }

            case .invite(let invite):
                MessageInviteContainerView(
                    invite: invite,
                    style: state.bubbleStyle,
                    isOutgoing: state.isOutgoing,
                    profile: message.base.sender.profile,
                    onTapInvite: { _ in },
                    onTapAvatar: nil
                )

            default:
                EmptyView()
            }
        }
        .contentShape(Rectangle())
        .frame(width: sourceBubble.width)
        .fixedSize(horizontal: false, vertical: true)
        .scaleEffect(scale, anchor: .center)
        .frame(width: rect.width, height: rect.height, alignment: .center)
        .clipped()
        .offset(x: rect.minX, y: rect.minY)
        .shadow(
            color: .black.opacity(appeared ? 0.25 : 0.0),
            radius: appeared ? 32 : 0,
            x: 0,
            y: appeared ? 12 : 0
        )
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: appeared)
    }

    @ViewBuilder
    private func photoPreview(attachment: HydratedAttachment, message: AnyMessage) -> some View {
        ContextMenuPhotoPreview(
            attachmentKey: attachment.key,
            isOutgoing: state.isOutgoing,
            profile: message.base.sender.profile,
            shouldBlur: shouldBlurPhoto,
            cornerRadius: appeared ? C.photoCornerRadius : 0
        )
    }

    // MARK: - Action Menu

    private func actionMenu(message: AnyMessage, bubbleRect: CGRect) -> some View {
        let finalY = bubbleRect.maxY + C.sectionSpacing
        let anchorX = state.isOutgoing ? bubbleRect.maxX : bubbleRect.minX

        return GlassEffectContainer {
            VStack(spacing: 0) {
                let replyAction = {
                    Log.info("[ContextMenu] Reply action fired")
                    let msg = message
                    dismissMenu()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        onReply(msg)
                    }
                }
                menuRow(icon: "arrowshape.turn.up.left", title: "Reply", action: replyAction)

                if let text = copyableText {
                    menuDivider
                    let copyAction = {
                        dismissMenu()
                        onCopy(text)
                    }
                    menuRow(icon: "doc.on.doc", title: "Copy", action: copyAction)
                }

                if let attachment = photoAttachment {
                    menuDivider
                    let saveAction = {
                        Log.info("[ContextMenu] Save action fired")
                        savePhoto(attachmentKey: attachment.key)
                        dismissMenu()
                    }
                    menuRow(icon: "square.and.arrow.down", title: "Save", action: saveAction)

                    menuDivider
                    let isBlurred = shouldBlurPhoto
                    let key = attachment.key
                    let revealCallback = onPhotoRevealed
                    let hideCallback = onPhotoHidden
                    let toggleAction = {
                        Log.info("[ContextMenu] Toggle action fired, isBlurred=\(isBlurred), key=\(key.prefix(30))...")
                        if isBlurred {
                            Log.info("[ContextMenu] Calling reveal")
                            blurOverride = false
                            revealCallback(key)
                        } else {
                            Log.info("[ContextMenu] Calling hide")
                            blurOverride = true
                            hideCallback(key)
                        }
                        dismissMenuAfterStateChange()
                    }
                    menuRow(
                        icon: isBlurred ? "eye" : "eye.slash",
                        title: isBlurred ? "Reveal" : "Blur",
                        action: toggleAction
                    )
                }
            }
            .foregroundStyle(.primary)
            .opacity(appeared ? 1.0 : 0.0)
            .animation(
                .spring(response: 0.29, dampingFraction: 0.8).delay(0.087),
                value: appeared
            )
            .frame(width: C.menuWidth)
            .clipShape(.rect(cornerRadius: C.menuCornerRadius))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: C.menuCornerRadius))
        }
        .fixedSize()
        .scaleEffect(
            appeared ? 1.0 : 0.01,
            anchor: state.isOutgoing ? .topTrailing : .topLeading
        )
        .offset(
            x: state.isOutgoing ? anchorX - C.menuWidth : anchorX,
            y: appeared ? finalY : bubbleRect.midY
        )
        .opacity(appeared ? 1.0 : 0.0)
        .animation(.spring(response: 0.36, dampingFraction: 0.78).delay(0.022), value: appeared)
    }

    // MARK: - Helpers

    private func savePhoto(attachmentKey: String) {
        guard let image = ImageCache.shared.image(for: attachmentKey) else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        }
    }

    private func menuRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: C.menuIconSpacing) {
                Image(systemName: icon)
                    .frame(width: C.menuIconWidth)
                Text(title)
                Spacer()
            }
            .font(.body)
            .padding(.horizontal, C.actionPaddingH)
            .padding(.vertical, C.actionPaddingV)
            .contentShape(Rectangle())
        }
    }

    private var menuDivider: some View {
        Divider()
            .padding(.horizontal, C.actionPaddingH)
    }

    private func dismissMenu() {
        showingEmojiPicker = false
        withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
            appeared = false
            emojiAppeared = Array(repeating: false, count: C.defaultReactions.count)
            showMoreAppeared = false
            selectedEmoji = nil
            customEmoji = nil
            popScale = 1.0
            drawerExpanded = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            state.dismiss()
            blurOverride = nil
        }
    }

    private func dismissMenuAfterStateChange() {
        showingEmojiPicker = false
        withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
            appeared = false
            emojiAppeared = Array(repeating: false, count: C.defaultReactions.count)
            showMoreAppeared = false
            selectedEmoji = nil
            customEmoji = nil
            popScale = 1.0
            drawerExpanded = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            state.dismiss()
            blurOverride = nil
        }
    }

    // swiftlint:disable type_name
    private enum C {
        static let sectionSpacing: CGFloat = 8
        static let padding: CGFloat = 8
        static let drawerHeight: CGFloat = 56
        static let expandedWidth: CGFloat = 280
        static let compactWidth: CGFloat = 112
        static let collapsedWidth: CGFloat = 72
        static let emojiFontSize: CGFloat = 24
        static let selectedEmojiFontSize: CGFloat = 28
        static let selectedEmojiFrame: CGFloat = 32
        static let faceSmilingFontSize: CGFloat = 28
        static let plusIconFontSize: CGFloat = 24
        static let plusTrailingPadding: CGFloat = 8
        static let blurRadius: CGFloat = 10
        static let emojiRotation: Double = -15
        static let emojiAppearanceDelayStep: TimeInterval = 0.036
        static let menuWidth: CGFloat = 200
        static let menuCornerRadius: CGFloat = 14
        static let actionPaddingH: CGFloat = 24
        static let actionPaddingV: CGFloat = 16
        static let menuIconWidth: CGFloat = 24
        static let menuIconSpacing: CGFloat = 12
        static let topInset: CGFloat = 56
        static let maxPreviewHeight: CGFloat = 75
        static let photoHorizontalInset: CGFloat = 16
        static let photoCornerRadius: CGFloat = DesignConstants.CornerRadius.photo
        static let textMenuEstimatedHeight: CGFloat = 100
        static let photoMenuEstimatedHeight: CGFloat = 220
        static let verticalBreathingRoom: CGFloat = 80

        static let defaultReactions: [String] = ["❤️", "👍", "👎", "😂", "😮", "🤔"]
    }
    // swiftlint:enable type_name
}

// MARK: - Context Menu Photo Preview

private struct ContextMenuPhotoPreview: View {
    let attachmentKey: String
    let isOutgoing: Bool
    let profile: Profile
    let shouldBlur: Bool
    let cornerRadius: CGFloat

    @State private var loadedImage: UIImage?

    init(attachmentKey: String, isOutgoing: Bool, profile: Profile, shouldBlur: Bool, cornerRadius: CGFloat = DesignConstants.CornerRadius.photo) {
        self.attachmentKey = attachmentKey
        self.isOutgoing = isOutgoing
        self.profile = profile
        self.shouldBlur = shouldBlur
        self.cornerRadius = cornerRadius
        _loadedImage = State(initialValue: ImageCache.shared.image(for: attachmentKey))
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                ZStack(alignment: isOutgoing ? .bottomTrailing : .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(shouldBlur ? 1.65 : 1.0)
                        .blur(radius: shouldBlur ? 96 : 0)

                    PhotoSenderLabel(profile: profile, isOutgoing: isOutgoing)
                }
                .clipped()
                .overlay(alignment: isOutgoing ? .bottom : .top) {
                    PhotoEdgeGradient(isOutgoing: isOutgoing)
                }
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.quaternary)
            }
        }
        .task {
            guard loadedImage == nil else { return }
            if let cachedImage = await ImageCache.shared.imageAsync(for: attachmentKey) {
                loadedImage = cachedImage
            }
        }
    }
}
