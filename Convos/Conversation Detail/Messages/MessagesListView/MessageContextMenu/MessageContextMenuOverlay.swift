import ConvosCore
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
    @State private var dragOffset: CGFloat = 0
    @State private var isDragDismissing: Bool = false
    @State private var isPoofDismissing: Bool = false
    @State private var keyboardHeight: CGFloat = 0

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

    private var formattedTimestamp: String? {
        guard let message else { return nil }
        let date = message.base.date
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let timeString = timeFormatter.string(from: date)

        if Calendar.current.isDateInToday(date) {
            return "Today · \(timeString)"
        } else if Calendar.current.isDateInYesterday(date) {
            return "Yesterday · \(timeString)"
        } else if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "EEEE"
            return "\(dayFormatter.string(from: date)) · \(timeString)"
        } else if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "MMM d"
            return "\(dayFormatter.string(from: date)) · \(timeString)"
        } else {
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "MMM d, yyyy"
            return "\(dayFormatter.string(from: date)) · \(timeString)"
        }
    }

    private var shouldBlurPhoto: Bool {
        if let blurOverride { return blurOverride }
        guard let photoAttachment, let message else { return false }
        if photoAttachment.isHiddenByOwner { return true }
        if message.base.sender.isCurrentUser { return false }
        return shouldBlurPhotos && !photoAttachment.isRevealed
    }

    private var windowSafeTop: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.safeAreaInsets.top ?? 0
    }

    var body: some View {
        if let message = state.presentedMessage {
            GeometryReader { proxy in
                let overlayOrigin = proxy.frame(in: .global).origin
                let screenSize = proxy.size
                let safeTop = max(proxy.safeAreaInsets.top, windowSafeTop)
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
                    isPhoto: isPhoto && !state.isReplyParent
                )
                let activeBubble = appeared ? endBubble : localBubble
                let keyboardTop = keyboardHeight > 0 ? screenSize.height - keyboardHeight : screenSize.height
                let bubbleBottom = activeBubble.maxY + C.sectionSpacing
                let keyboardOverlap = max(bubbleBottom - keyboardTop + C.sectionSpacing, 0)
                let keyboardAdjustment = showingEmojiPicker ? keyboardOverlap : 0

                ZStack(alignment: .topLeading) {
                    backgroundDimming

                    reactionsBar(
                        messageId: message.base.id,
                        bubbleRect: activeBubble,
                        sourceBubble: localBubble,
                        keyboardAdjustment: keyboardAdjustment,
                        minBarY: safeTop
                    )
                    .zIndex(1)

                    actionMenu(
                        message: message,
                        bubbleRect: activeBubble
                    )
                    .zIndex(2)

                    bubblePreview(
                        message: message,
                        sourceBubble: localBubble,
                        endBubble: endBubble,
                        keyboardAdjustment: keyboardAdjustment
                    )
                    .zIndex(3)
                }
            }
            .ignoresSafeArea()
            .onAppear {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                emojiAppeared = Array(repeating: false, count: C.defaultReactions.count)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
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
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    keyboardHeight = frame.height
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    keyboardHeight = 0
                }
            }
        }
    }

    // MARK: - Background

    private var dragDismissProgress: CGFloat {
        min(max(dragOffset / C.dragDismissThreshold, 0), 1.0)
    }

    private var backgroundDimming: some View {
        Color.black.opacity(0.15)
            .background(.ultraThinMaterial.opacity(0.4))
            .opacity(appeared && !isDragDismissing ? 1.0 - dragDismissProgress : 0.0)
            .animation(.easeOut(duration: 0.14), value: appeared)
            .onTapGesture { dismissMenu() }
            .accessibilityLabel("Dismiss menu")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Reactions Bar

    private func reactionsBar(
        messageId: String,
        bubbleRect: CGRect,
        sourceBubble: CGRect,
        keyboardAdjustment: CGFloat,
        minBarY: CGFloat
    ) -> some View {
        let startSize: CGFloat = min(sourceBubble.height, sourceBubble.width)
        let drawerWidth: CGFloat = drawerExpanded ? C.expandedWidth : (selectedEmoji != nil ? C.collapsedWidth : C.compactWidth)
        let currentWidth: CGFloat = appeared ? drawerWidth : startSize
        let currentHeight: CGFloat = appeared ? C.drawerHeight : startSize

        let endY: CGFloat = max(bubbleRect.minY - C.drawerHeight - C.sectionSpacing, minBarY)
        let endX: CGFloat = state.isOutgoing ? bubbleRect.maxX - drawerWidth : bubbleRect.minX
        let startY: CGFloat = sourceBubble.midY - startSize / 2
        let startX: CGFloat = state.isOutgoing ? sourceBubble.maxX - startSize : sourceBubble.minX
        let barX: CGFloat = appeared ? endX : startX
        let barY: CGFloat = appeared ? endY : startY

        return GlassEffectContainer {
            reactionsBarContent(messageId: messageId, width: currentWidth, height: currentHeight)
        }
        .frame(width: currentWidth, height: currentHeight)
        .scaleEffect(
            (appeared ? 1.0 : 0.01) * (1.0 - dragDismissProgress * 0.5),
            anchor: state.isOutgoing ? .bottomTrailing : .bottomLeading
        )
        .offset(x: barX, y: barY + dragOffset * C.menuDragFollowRatio - keyboardAdjustment)
        .opacity(isDragDismissing ? 0.0 : (appeared ? 1.0 : 0.0) * (1.0 - dragDismissProgress))
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: appeared)
        .animation(.spring(response: 0.29, dampingFraction: 0.7), value: drawerExpanded)
        .animation(.spring(response: 0.29, dampingFraction: 0.8), value: selectedEmoji)
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.7), value: dragOffset)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: keyboardAdjustment)
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

    @ViewBuilder
    private func reactionsBarContent(messageId: String, width: CGFloat, height: CGFloat) -> some View {
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
                            .buttonStyle(.plain)
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
                            .foregroundStyle(.colorTextSecondary)
                            .opacity(!drawerExpanded && selectedEmoji == nil && customEmoji == nil ? 1.0 : 0)
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
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .frame(minWidth: readerHeight, minHeight: readerHeight)
                    .padding(.horizontal, C.plusHorizontalPadding)
                    .scaleEffect(selectedEmoji == nil ? 1.0 : 0)
                    .animation(.spring(response: 0.29, dampingFraction: 0.8), value: selectedEmoji)
                    .animation(.spring(response: 0.29, dampingFraction: 0.7), value: drawerExpanded)
                }
            }
            .animation(.spring(response: 0.29, dampingFraction: 0.7), value: drawerExpanded)
        }
        .frame(width: width, height: height)
        .clipShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func selectReaction(_ emoji: String, messageId: String) {
        selectedEmoji = emoji
        onReaction(emoji, messageId)

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

        let finalX: CGFloat
        let finalY: CGFloat

        if isPhoto {
            let availableHeight: CGFloat = screenSize.height - minY - bottomPadding
            let centeredY: CGFloat = minY + (availableHeight - endHeight) / 2
            finalX = state.isOutgoing
                ? screenSize.width - endWidth - C.photoHorizontalInset
                : C.photoHorizontalInset
            finalY = max(centeredY, minY)
        } else {
            finalX = state.isOutgoing ? source.maxX - endWidth : source.minX
            let maxY: CGFloat = screenSize.height - bottomPadding - endHeight
            finalY = max(min(source.minY, maxY), minY)
        }

        return CGRect(x: finalX, y: finalY, width: endWidth, height: endHeight)
    }

    // MARK: - Bubble Preview

    @ViewBuilder
    private func bubblePreview(
        message: AnyMessage,
        sourceBubble: CGRect,
        endBubble: CGRect,
        keyboardAdjustment: CGFloat
    ) -> some View {
        let dismissToSource = !isPoofDismissing
        let rect = appeared ? endBubble : (dismissToSource ? sourceBubble : endBubble)
        let endScale: CGFloat = min(endBubble.width / max(sourceBubble.width, 1), 1.0)
        let poofScale: CGFloat = endScale * 1.15
        let scale: CGFloat = appeared ? endScale : (dismissToSource ? 1.0 : poofScale)
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
                if attachment.mediaType == .file {
                    FileAttachmentBubble(
                        attachment: attachment,
                        isOutgoing: state.isOutgoing,
                        profile: message.base.sender.profile
                    )
                } else {
                    ContextMenuPhotoPreview(
                        attachmentKey: attachment.key, isOutgoing: state.isOutgoing,
                        profile: message.base.sender.profile, shouldBlur: shouldBlurPhoto,
                        cornerRadius: state.isReplyParent ? DesignConstants.CornerRadius.regular : (appeared ? C.photoCornerRadius : 0),
                        showSenderLabel: !state.isReplyParent, isReplyParent: state.isReplyParent
                    )
                }

            case .attachments(let attachments):
                if let attachment = attachments.first {
                    if attachment.mediaType == .file {
                        FileAttachmentBubble(
                            attachment: attachment,
                            isOutgoing: state.isOutgoing,
                            profile: message.base.sender.profile
                        )
                    } else {
                        ContextMenuPhotoPreview(
                            attachmentKey: attachment.key, isOutgoing: state.isOutgoing,
                            profile: message.base.sender.profile, shouldBlur: shouldBlurPhoto,
                            cornerRadius: state.isReplyParent ? DesignConstants.CornerRadius.regular : (appeared ? C.photoCornerRadius : 0),
                            showSenderLabel: !state.isReplyParent, isReplyParent: state.isReplyParent
                        )
                    }
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
        .blur(radius: !appeared && isPoofDismissing ? 8 : 0)
        .opacity(!appeared && isPoofDismissing ? 0 : 1)
        .offset(x: rect.minX, y: rect.minY + dragOffset - keyboardAdjustment)
        .shadow(
            color: .black.opacity(appeared ? 0.25 * (1.0 - dragDismissProgress) : 0.0),
            radius: appeared ? 32 * (1.0 - dragDismissProgress) : 0,
            x: 0,
            y: appeared ? 12 * (1.0 - dragDismissProgress) : 0
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: appeared)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: keyboardAdjustment)
        .onTapGesture {
            dismissMenu()
        }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    if value.translation.height > C.dragDismissThreshold ||
                        value.predictedEndTranslation.height > C.dragDismissThreshold * 2 {
                        isDragDismissing = true
                        dismissMenu()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: dragOffset)
    }

    // MARK: - Action Menu

    private func actionMenu(message: AnyMessage, bubbleRect: CGRect) -> some View {
        let finalY = bubbleRect.maxY + C.sectionSpacing
        let anchorX = state.isOutgoing ? bubbleRect.maxX : bubbleRect.minX

        return GlassEffectContainer {
            VStack(spacing: 0) {
                if let formattedTimestamp {
                    Text(formattedTimestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                }

                let replyAction = {
                    let msg = message
                    dismissMenu()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        onReply(msg)
                    }
                }
                ContextMenuRow(icon: "arrowshape.turn.up.left", title: "Reply", action: replyAction)

                if let text = copyableText {
                    let copyAction = {
                        dismissMenu()
                        onCopy(text)
                    }
                    ContextMenuRow(icon: "doc.on.doc", title: "Copy", action: copyAction)
                }

                if let attachment = photoAttachment {
                    if attachment.mediaType == .file {
                        let saveToFilesAction = {
                            dismissMenu()
                            saveFileToFiles(key: attachment.key, filename: attachment.filename)
                        }
                        ContextMenuRow(icon: "folder", title: "Save to Files", action: saveToFilesAction)

                        let shareAction = {
                            dismissMenu()
                            shareFile(key: attachment.key, filename: attachment.filename)
                        }
                        ContextMenuRow(icon: "square.and.arrow.up", title: "Share", action: shareAction)
                    } else {
                        let saveAction = {
                            if attachment.mediaType == .video {
                                saveVideoToPhotoLibrary(key: attachment.key)
                            } else {
                                saveAttachmentToPhotoLibrary(key: attachment.key)
                            }
                            dismissMenu()
                        }
                        ContextMenuRow(icon: "square.and.arrow.down", title: "Save", action: saveAction)

                        let isBlurred = shouldBlurPhoto
                        let key = attachment.key
                        let revealCallback = onPhotoRevealed
                        let hideCallback = onPhotoHidden
                        let toggleAction = {
                            if isBlurred {
                                blurOverride = false
                                revealCallback(key)
                            } else {
                                blurOverride = true
                                hideCallback(key)
                            }
                            dismissMenu(afterStateChange: true)
                        }
                        ContextMenuRow(
                            icon: isBlurred ? "eye" : "eye.slash",
                            title: isBlurred ? "Reveal" : "Blur",
                            action: toggleAction
                        )
                    }
                }
            }
            .padding(.vertical, 10)
            .foregroundStyle(.primary)
            .opacity(appeared ? 1.0 : 0.0)
            .animation(
                .spring(response: 0.29, dampingFraction: 0.8).delay(0.05),
                value: appeared
            )
            .frame(width: C.menuWidth)
            .clipShape(.rect(cornerRadius: C.menuCornerRadius))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: C.menuCornerRadius))
        }
        .fixedSize()
        .scaleEffect(
            (appeared && !showingEmojiPicker ? 1.0 : 0.01) * (1.0 - dragDismissProgress * 0.5),
            anchor: state.isOutgoing ? .topTrailing : .topLeading
        )
        .offset(
            x: state.isOutgoing ? anchorX - C.menuWidth : anchorX,
            y: (appeared ? finalY : bubbleRect.midY) + dragOffset * C.menuDragFollowRatio
        )
        .opacity(isDragDismissing ? 0.0 : (appeared && !showingEmojiPicker ? 1.0 : 0.0) * (1.0 - dragDismissProgress))
        .animation(.spring(response: 0.28, dampingFraction: 0.78).delay(0.012), value: appeared)
        .animation(.spring(response: 0.29, dampingFraction: 0.8), value: showingEmojiPicker)
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.7), value: dragOffset)
    }

    private func dismissMenu(afterStateChange: Bool = false) {
        showingEmojiPicker = false
        if state.sourceFrameMoved {
            isPoofDismissing = true
        }

        let wasDragDismiss = isDragDismissing
        let animation: Animation = wasDragDismiss && !afterStateChange
            ? .spring(response: 0.25, dampingFraction: 0.85)
            : .spring(response: 0.18, dampingFraction: 0.9)
        withAnimation(animation) {
            appeared = false
            dragOffset = 0
            emojiAppeared = Array(repeating: false, count: C.defaultReactions.count)
            showMoreAppeared = false
            selectedEmoji = nil
            customEmoji = nil
            popScale = 1.0
            drawerExpanded = true
        }
        let delay: TimeInterval = afterStateChange ? 0.3 : (wasDragDismiss ? 0.28 : 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            state.dismiss()
            blurOverride = nil
            isDragDismissing = false
            isPoofDismissing = false
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
        static let plusHorizontalPadding: CGFloat = 8
        static let blurRadius: CGFloat = 10
        static let emojiRotation: Double = -15
        static let emojiAppearanceDelayStep: TimeInterval = 0.025
        static let menuWidth: CGFloat = 250
        static let menuCornerRadius: CGFloat = 32
        static let actionPaddingH: CGFloat = 28
        static let actionPaddingV: CGFloat = 11
        static let menuIconWidth: CGFloat = 18
        static let menuIconSpacing: CGFloat = 14
        static let topInset: CGFloat = 56
        static let maxPreviewHeight: CGFloat = 75
        static let photoHorizontalInset: CGFloat = 16
        static let photoCornerRadius: CGFloat = DesignConstants.CornerRadius.photo
        static let textMenuEstimatedHeight: CGFloat = 80
        static let photoMenuEstimatedHeight: CGFloat = 160
        static let verticalBreathingRoom: CGFloat = 80

        static let dragDismissThreshold: CGFloat = 150
        static let menuDragFollowRatio: CGFloat = 0.6

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
    let showSenderLabel: Bool
    let isReplyParent: Bool

    @State private var loadedImage: UIImage?

    init(
        attachmentKey: String,
        isOutgoing: Bool,
        profile: Profile,
        shouldBlur: Bool,
        cornerRadius: CGFloat = DesignConstants.CornerRadius.photo,
        showSenderLabel: Bool = true,
        isReplyParent: Bool = false
    ) {
        self.attachmentKey = attachmentKey
        self.isOutgoing = isOutgoing
        self.profile = profile
        self.shouldBlur = shouldBlur
        self.cornerRadius = cornerRadius
        self.showSenderLabel = showSenderLabel
        self.isReplyParent = isReplyParent
        _loadedImage = State(initialValue: ImageCache.shared.image(for: attachmentKey))
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                ZStack(alignment: isOutgoing ? .bottomTrailing : .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: shouldBlur && !isReplyParent ? .fill : .fit)
                        .scaleEffect(shouldBlur ? 1.65 : 1.0)
                        .blur(radius: shouldBlur ? 96 : 0)
                        .background(shouldBlur ? Color.colorBackgroundSurfaceless : .clear)

                    if showSenderLabel {
                        PhotoSenderLabel(profile: profile, isOutgoing: isOutgoing)
                    }
                }
                .clipped()
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

// MARK: - Save Attachment Helper

private func saveAttachmentToPhotoLibrary(key: String) {
    guard let image = ImageCache.shared.image(for: key) else { return }
    PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.creationRequestForAsset(from: image)
    }
}

private func saveVideoToPhotoLibrary(key: String) {
    Task {
        do {
            let videoURL: URL
            let isLocalFile = key.hasPrefix("file://")
            if isLocalFile {
                let path = String(key.dropFirst("file://".count))
                videoURL = URL(fileURLWithPath: path)
            } else {
                let loader = RemoteAttachmentLoader()
                let loaded = try await loader.loadAttachmentData(from: key)
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("save_video_\(UUID().uuidString).mp4")
                try loaded.data.write(to: tempURL)
                videoURL = tempURL
            }

            defer {
                if !isLocalFile {
                    try? FileManager.default.removeItem(at: videoURL)
                }
            }

            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            }
        } catch {
            Log.error("Failed to save video to photo library: \(error)")
        }
    }
}

// MARK: - File Save/Share Helpers

private func loadFileToTempURL(key: String, filename: String?) async throws -> URL {
    if key.hasPrefix("file://") {
        let path = String(key.dropFirst("file://".count))
        return URL(fileURLWithPath: path)
    }

    let loader = RemoteAttachmentLoader()
    let loaded = try await loader.loadAttachmentData(from: key)
    let name = filename ?? "attachment"
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("share_\(UUID().uuidString)_\(name)")
    try loaded.data.write(to: tempURL)
    return tempURL
}

private func saveFileToFiles(key: String, filename: String?) {
    Task { @MainActor in
        do {
            let tempURL = try await loadFileToTempURL(key: key, filename: filename)
            let picker = UIDocumentPickerViewController(forExporting: [tempURL])
            picker.shouldShowFileExtensions = true
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let root = scene.keyWindow?.rootViewController else { return }
            var presenter = root
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            presenter.present(picker, animated: true)
        } catch {
            Log.error("Failed to save file: \(error)")
        }
    }
}

private func shareFile(key: String, filename: String?) {
    Task { @MainActor in
        do {
            let tempURL = try await loadFileToTempURL(key: key, filename: filename)
            let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let root = scene.keyWindow?.rootViewController else { return }
            var presenter = root
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            activityVC.popoverPresentationController?.sourceView = presenter.view
            activityVC.popoverPresentationController?.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0, height: 0
            )
            presenter.present(activityVC, animated: true)
        } catch {
            Log.error("Failed to share file: \(error)")
        }
    }
}

// MARK: - Context Menu Row

private struct ContextMenuRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 18)
                Text(title)
                    .font(.body)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
    }
}
