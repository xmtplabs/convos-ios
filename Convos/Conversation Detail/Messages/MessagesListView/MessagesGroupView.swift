import ConvosCore
import ConvosLogging
import SwiftUI

struct MessagesGroupView: View {
    let group: MessagesGroup
    let conversationId: String
    let shouldBlurPhotos: Bool
    let onTapAvatar: (AnyMessage) -> Void
    let onTapInvite: (MessageInvite) -> Void
    let onTapReactions: (AnyMessage) -> Void
    var onTapReadReceipts: ((MessagesGroup) -> Void)?
    var onTapThinkingIndicator: ((ThinkingSessionDescriptor) -> Void)?
    let onReaction: (String, String) -> Void
    let onToggleReaction: (String, String) -> Void
    let onReply: (AnyMessage) -> Void
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    var onOpenFile: ((HydratedAttachment, AnyMessage) -> Void)?
    var onRetryMessage: ((AnyMessage) -> Void)?
    var onDeleteMessage: ((AnyMessage) -> Void)?
    var onRetryTranscript: ((VoiceMemoTranscriptListItem) -> Void)?
    var allVoiceMemoTranscripts: [String: VoiceMemoTranscriptListItem] = [:]

    @Environment(\.displayScale) private var displayScale: CGFloat
    @State private var isAppearing: Bool = true
    @State private var hasAnimated: Bool = false

    private var animates: Bool {
        group.messages.first?.origin == .inserted
    }

    private var avatarWidth: CGFloat {
        group.sender.isCurrentUser ? 0 : DesignConstants.ImageSizes.smallAvatar + DesignConstants.Spacing.step2x
    }

    private var avatarSize: CGFloat {
        DesignConstants.ImageSizes.smallAvatar
    }

    private var avatarSpacing: CGFloat {
        DesignConstants.Spacing.step2x
    }

    private var senderLabel: some View {
        senderLabelContent
            .scaleEffect(isAppearing ? 0.9 : 1.0)
            .opacity(isAppearing ? 0.0 : 1.0)
            .offset(x: 0.0, y: isAppearing ? 100 : 0)
            .blur(radius: isAppearing ? 10.0 : 0.0)
            .font(.footnote)
            .foregroundColor(group.sender.isAgent ? group.sender.agentVerification.nameColor : .secondary)
            .padding(.leading, avatarWidth + DesignConstants.Spacing.step4x + DesignConstants.Spacing.step3x)
            .padding(.bottom, DesignConstants.Spacing.stepHalf)
    }

    private var senderLabelContent: some View {
        let tapAction = { if let msg = group.allMessages.first { onTapAvatar(msg) } }
        return Button(action: tapAction) {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Text(group.sender.profile.displayName)
                if group.sender.isAgent && group.sender.profile.isOutOfCredits {
                    Image(systemName: "battery.0percent")
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func avatarOverlay(onTap: (() -> Void)? = nil) -> some View {
        MessageAvatarView(profile: group.sender.profile, size: avatarSize, agentVerification: group.sender.agentVerification)
            .offset(x: -(avatarSize + avatarSpacing))
            .onTapGesture { onTap?() }
            .scaleEffect(isAppearing ? 0.9 : 1.0)
            .opacity(isAppearing ? 0.0 : 1.0)
            .offset(
                x: isAppearing ? -80 : 0,
                y: 0.0
            )
            .id("profile-\(group.id)")
            .accessibilityLabel("View \(group.sender.profile.displayName)'s profile")
            .accessibilityAddTraits(.isButton)
    }

    private var singleTyperIndicator: some View {
        let isTypingOnly = group.allMessages.isEmpty

        return Group {
            if isTypingOnly && !group.sender.isCurrentUser {
                senderLabel
            }

            HStack(alignment: .bottom, spacing: avatarSpacing) {
                if !group.sender.isCurrentUser {
                    Color.clear
                        .frame(width: avatarSize, height: avatarSize)
                }

                TypingIndicatorBubbleView(senderName: group.sender.profile.displayName)
                    .overlay(alignment: .bottomLeading) {
                        if !group.sender.isCurrentUser {
                            avatarOverlay()
                        }
                    }
            }
            .padding(.leading, !group.sender.isCurrentUser ? DesignConstants.Spacing.step4x : 0)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))
        .id("typing-indicator-\(group.id)")
    }

    private var thinkingIndicator: some View {
        HStack(alignment: .bottom, spacing: avatarSpacing) {
            if !group.sender.isCurrentUser {
                Color.clear
                    .frame(width: avatarSize, height: avatarSize)
            }

            ThinkingIndicatorBubbleView(
                content: group.thinkingContent ?? "",
                senderName: group.sender.profile.displayName,
                hidesContent: true
            )
            .overlay(alignment: .bottomLeading) {
                if !group.sender.isCurrentUser {
                    avatarOverlay()
                }
            }
        }
        .padding(.leading, !group.sender.isCurrentUser ? DesignConstants.Spacing.step4x : 0)
        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))
        .id("thinking-indicator-bubble-\(group.id)")
    }

    private var multiTyperIndicator: some View {
        let typers = group.allTypingMembers
        let names = typers.compactMap(\.profile.displayName)
        let accessibilityText: String = {
            switch names.count {
            case 0: return "People are typing"
            case 1: return "\(names[0]) is typing"
            case 2: return "\(names[0]) and \(names[1]) are typing"
            default: return "\(names.count) people are typing"
            }
        }()

        let visibleCount = min(typers.count, 3)
        let overlapOffset: CGFloat = 8
        let stackWidth = avatarSize + CGFloat(visibleCount - 1) * (avatarSize - overlapOffset)

        return HStack(alignment: .bottom, spacing: avatarSpacing) {
            HStack(spacing: -overlapOffset) {
                ForEach(Array(typers.prefix(3).enumerated()), id: \.element.id) { index, member in
                    MessageAvatarView(profile: member.profile, size: avatarSize)
                        .overlay(
                            Circle()
                                .stroke(Color(.systemBackground), lineWidth: 2)
                        )
                        .zIndex(Double(index))
                }
            }
            .frame(width: stackWidth, alignment: .leading)

            TypingIndicatorBubbleView(senderName: nil)
        }
        .padding(.leading, DesignConstants.Spacing.step4x)
        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .id("typing-indicator-multi")
    }

    @ViewBuilder
    private func messageGroup(index: Int, message: AnyMessage) -> some View {
        let isReply: Bool = if case .reply = message { true } else { false }
        let isFullWidthAttachment: Bool = message.content.isFullBleedAttachment

        // The sender label is hoisted to the body via `shouldShowSenderLabelAtTop`
        // so it can sit above the assistant contact card prefix as well as the
        // first message bubble.
        if index == 0 && !group.sender.isCurrentUser && !isFullWidthAttachment && !isReply
            && group.assistantContactCard == nil && !group.hidesSenderLabel {
            senderLabel
        }

        let isLastInGroup: Bool = message == group.messages.last
        let isLast: Bool = isLastInGroup && !group.showsTypingIndicator && !group.showsThinkingIndicator
        // When the last message is a voice memo with a transcript row attached, the
        // transcript becomes the visual bottom of the group, so the tail moves from
        // the voice memo bubble down onto the transcript row.
        let transcriptIsTailed: Bool = isLast && group.voiceMemoTranscripts[message.messageId] != nil
        let bubbleType: MessageBubbleType = (isLast && !transcriptIsTailed) ? .tailed : .normal
        let showsSentStatus: Bool = isLastInGroup && (group.isLastGroupSentByCurrentUser || group.isLastGroupBeforeOtherMembers) && message.status == .published
        let isFailed: Bool = message.sender.isCurrentUser && message.status == .failed

        messageRowContent(
            message: message,
            bubbleType: bubbleType,
            isFailed: isFailed,
            isLast: isLast,
            isFullWidthAttachment: isFullWidthAttachment,
            voiceMemoTranscriptIsTailed: transcriptIsTailed
        )
        reactionRow(message: message, isFullWidthAttachment: isFullWidthAttachment)

        let thinkingDescriptor: ThinkingSessionDescriptor? = group.thinkingByMessageId[message.messageId]
        let mergesThinkingIntoStatus: Bool = showsSentStatus && thinkingDescriptor != nil && !group.onlyVisibleToSender
        if mergesThinkingIntoStatus, let descriptor = thinkingDescriptor {
            mergedThinkingStatusRow(message: message, descriptor: descriptor)
        } else {
            thinkingFooterRow(message: message)
            statusRow(message: message, isFailed: isFailed, showsSentStatus: showsSentStatus)
        }
    }

    @ViewBuilder
    private func mergedThinkingStatusRow(message: AnyMessage, descriptor: ThinkingSessionDescriptor) -> some View {
        let assistant: ConversationMember = descriptor.sender
        let dedupedReaders: [ConversationMember] = group.readByMembers.filter { $0.profile.inboxId != assistant.profile.inboxId }
        let hasOtherReaders: Bool = !dedupedReaders.isEmpty
        let tap: () -> Void = { onTapThinkingIndicator?(descriptor) }

        HStack(spacing: DesignConstants.Spacing.stepX) {
            Spacer()
            Button(action: tap) {
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    MergedThinkingCaption(descriptor: descriptor, showsLeadingAvatar: !hasOtherReaders)
                    if hasOtherReaders {
                        ReadReceiptAvatarsView(members: [assistant] + dedupedReaders)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(descriptor.sender.profile.displayName) is thinking: \(descriptor.content)")
            .accessibilityHint("Tap to see thinking details")
        }
        .transition(.blurReplace)
        .padding(.vertical, DesignConstants.Spacing.stepX)
        .padding(.leading, DesignConstants.Spacing.step2x)
        .padding(.trailing, DesignConstants.Spacing.step4x)
        .foregroundStyle(.colorTextSecondary)
        .zIndex(-1)
        .id("merged-thinking-receipt-\(message.differenceIdentifier)")
    }

    @ViewBuilder
    private func contactCardRow(card: AssistantContactCardInfo) -> some View {
        // The card is the visual "last item" of the group only when the
        // assistant hasn't sent any messages yet (synthesized empty group).
        // Otherwise the regular `messageRowContent` avatar overlay handles
        // the leading avatar on the last message — we don't want to double up.
        let cardIsLast: Bool = group.allMessages.isEmpty && !group.showsTypingIndicator && !group.showsThinkingIndicator
        HStack(alignment: .bottom, spacing: avatarSpacing) {
            if !group.sender.isCurrentUser {
                Color.clear
                    .frame(width: avatarSize, height: avatarSize)
            }

            AssistantContactCardView(profile: card.profile, assistantDescription: card.assistantDescription)
                .overlay(alignment: .bottomLeading) {
                    if cardIsLast && !group.sender.isCurrentUser {
                        avatarOverlay()
                    }
                }

            // Mirrors `MessageContainer.spacer` so the card caps at the same
            // max width as text bubbles — natural sizing for short content,
            // bounded by a 50pt trailing spacer with lower layout priority.
            Spacer()
                .frame(minWidth: 50.0)
                .layoutPriority(-1)
        }
        .padding(.leading, !group.sender.isCurrentUser ? DesignConstants.Spacing.step4x : 0)
    }

    @ViewBuilder
    private func messageRowContent(
        message: AnyMessage,
        bubbleType: MessageBubbleType,
        isFailed: Bool,
        isLast: Bool,
        isFullWidthAttachment: Bool,
        voiceMemoTranscriptIsTailed: Bool
    ) -> some View {
        HStack(alignment: .bottom, spacing: avatarSpacing) {
            if !group.sender.isCurrentUser && !isFullWidthAttachment {
                Color.clear
                    .frame(width: avatarSize, height: avatarSize)
            }

            if group.usesThoughtBubbleStyle, let text = thoughtBubbleText(for: message) {
                ThoughtBubbleAppearance(animates: message.origin == .inserted) {
                    HStack(spacing: 0.0) {
                        ThoughtBubble {
                            // Type spec from design: 16pt regular, 24pt
                            // line height, 0.3pt tracking. `.callout` is
                            // 16pt by default on iOS and scales with
                            // Dynamic Type. SF Pro 16pt's natural line
                            // height is ~19pt, so 5pt extra `lineSpacing`
                            // brings each line to ~24pt.
                            Text(text)
                                .font(.callout)
                                .tracking(0.3)
                                .lineSpacing(5.0)
                                .foregroundStyle(.colorTextSecondary)
                        }
                        Spacer(minLength: 50.0)
                            .layoutPriority(-1)
                    }
                }
                .zIndex(100)
                .id("messages-group-item-\(message.differenceIdentifier)")
                .overlay(alignment: .bottomLeading) {
                    if isLast && !group.sender.isCurrentUser {
                        avatarOverlay { onTapAvatar(message) }
                    }
                }
            } else {
                MessagesGroupItemView(
                    message: message,
                    conversationId: conversationId,
                    bubbleType: bubbleType,
                    shouldBlurPhotos: shouldBlurPhotos,
                    onTapAvatar: onTapAvatar,
                    onTapInvite: onTapInvite,
                    onReply: onReply,
                    onPhotoRevealed: onPhotoRevealed,
                    onPhotoHidden: onPhotoHidden,
                    onPhotoDimensionsLoaded: onPhotoDimensionsLoaded,
                    onOpenFile: onOpenFile,
                    onTapReactions: onTapReactions,
                    onReaction: onReaction,
                    onToggleReaction: onToggleReaction,
                    voiceMemoTranscript: group.voiceMemoTranscripts[message.messageId],
                    voiceMemoTranscriptIsTailed: voiceMemoTranscriptIsTailed,
                    onRetryTranscript: onRetryTranscript,
                    parentAudioTranscriptText: parentAudioTranscriptText(for: message),
                    omitTrailingPadding: isFailed
                )
                .zIndex(100)
                .id("messages-group-item-\(message.differenceIdentifier)")
                .transition(
                    .asymmetric(
                        insertion: .identity,
                        removal: .opacity
                    )
                )
                .overlay(alignment: .bottomLeading) {
                    if isLast && !group.sender.isCurrentUser {
                        avatarOverlay { onTapAvatar(message) }
                    }
                }
            }

            if isFailed {
                FailedMessageButton(
                    message: message,
                    onRetry: onRetryMessage,
                    onDelete: onDeleteMessage
                )
                .padding(.leading, DesignConstants.Spacing.step3x - avatarSpacing)
                .padding(.trailing, DesignConstants.Spacing.step4x)
            }
        }
        .padding(.leading, !group.sender.isCurrentUser && !isFullWidthAttachment ? DesignConstants.Spacing.step4x : 0)
    }

    /// Returns the plain text of `message` when it should render in a
    /// `ThoughtBubble` — i.e. the message is a `.message` with `.text`
    /// content. Reply / emoji / attachment / invite cases stay on the
    /// regular bubble path even when the group is in thought-bubble mode.
    private func thoughtBubbleText(for message: AnyMessage) -> String? {
        guard case .message(let inner, _) = message,
              case .text(let text) = inner.content else { return nil }
        return text
    }

    private func parentAudioTranscriptText(for message: AnyMessage) -> String? {
        guard case .reply(let reply, _) = message,
              reply.parentMessage.content.primaryVoiceMemoAttachment != nil
        else { return nil }
        return allVoiceMemoTranscripts[reply.parentMessage.id]?.text
    }

    @ViewBuilder
    private func reactionRow(message: AnyMessage, isFullWidthAttachment: Bool) -> some View {
        if !message.reactions.isEmpty, !isFullWidthAttachment {
            ReactionIndicatorView(
                reactions: message.reactions,
                isOutgoing: message.sender.isCurrentUser,
                onTap: { onTapReactions(message) }
            )
            .padding(.leading, message.sender.isCurrentUser ? 0 : (isFullWidthAttachment ? DesignConstants.Spacing.step4x : avatarWidth + avatarSpacing + DesignConstants.Spacing.step2x))
            .padding(.trailing, message.sender.isCurrentUser ? DesignConstants.Spacing.step4x : 0)
            .padding(.bottom, DesignConstants.Spacing.stepX)
            .transition(.identity)
            .zIndex(50)
            .id("reactions-\(message.differenceIdentifier)")
        }
    }

    /// Inline thinking footer anchored to the contact card (not to a
    /// specific message). The card row above already shows the assistant
    /// avatar, so this footer suppresses its own leading avatar to avoid
    /// visual duplication. Tap forwards to the same detail sheet as the
    /// per-message inline footers.
    @ViewBuilder
    private func contactCardThinkingFooterRow(descriptor: ThinkingSessionDescriptor) -> some View {
        let tap: () -> Void = { onTapThinkingIndicator?(descriptor) }
        HStack(spacing: 0) {
            ThinkingIndicatorFooterView(
                descriptor: descriptor,
                showsLeadingAvatar: false,
                onTap: tap
            )
            Spacer()
        }
        .padding(.leading, avatarWidth + DesignConstants.Spacing.step4x)
        .padding(.vertical, DesignConstants.Spacing.stepHalf)
        .transition(.opacity)
        .id("contact-card-thinking-\(descriptor.id)")
    }

    @ViewBuilder
    private func thinkingFooterRow(message: AnyMessage) -> some View {
        if let descriptor = group.thinkingByMessageId[message.messageId] {
            let isOutgoing: Bool = message.sender.isCurrentUser
            // Skip the leading avatar when the thinker is also the message's
            // sender — the message's avatar already conveys "who" on that side
            // of the conversation, so repeating it in the footer reads as noise.
            // Outgoing messages now keep the avatar too, since this row only
            // renders when there's no read-receipt row to fold into.
            let thinkerIsMessageSender: Bool = descriptor.sender.profile.inboxId == message.sender.profile.inboxId
            let showsLeadingAvatar: Bool = !thinkerIsMessageSender
            let footerTap: () -> Void = { onTapThinkingIndicator?(descriptor) }
            HStack(spacing: 0) {
                if isOutgoing {
                    Spacer()
                }
                ThinkingIndicatorFooterView(
                    descriptor: descriptor,
                    showsLeadingAvatar: showsLeadingAvatar,
                    onTap: footerTap
                )
                if !isOutgoing {
                    Spacer()
                }
            }
            .padding(.leading, isOutgoing ? 0 : (avatarWidth + DesignConstants.Spacing.step4x))
            .padding(.trailing, isOutgoing ? DesignConstants.Spacing.step4x : 0)
            .padding(.vertical, DesignConstants.Spacing.stepHalf)
            .transition(.opacity)
            .id("thinking-footer-\(message.messageId)")
        }
    }

    @ViewBuilder
    private func statusRow(message: AnyMessage, isFailed: Bool, showsSentStatus: Bool) -> some View {
        if isFailed {
            HStack(spacing: DesignConstants.Spacing.stepHalf) {
                Spacer()
                Text("Not Delivered")
            }
            .transition(.blurReplace)
            .padding(.vertical, DesignConstants.Spacing.stepX)
            .padding(.leading, DesignConstants.Spacing.step2x)
            .padding(.trailing, DesignConstants.Spacing.step4x)
            .font(.caption)
            .foregroundStyle(.colorCaution)
            .zIndex(-1)
            .id("failed-status-\(message.differenceIdentifier)")
            .accessibilityLabel("Message not delivered")
        } else if showsSentStatus {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Spacer()
                if group.onlyVisibleToSender {
                    Text("Only visible to you")
                        .font(.caption)
                    ProfileAvatarView(
                        profile: group.sender.profile,
                        profileImage: ProfileSettingsViewModel.shared.profileImage,
                        useSystemPlaceholder: false
                    )
                    .frame(width: 16, height: 16)
                } else if !group.readByMembers.isEmpty {
                    let readReceiptTap: () -> Void = { onTapReadReceipts?(group) }
                    Button(action: readReceiptTap) {
                        HStack(spacing: DesignConstants.Spacing.stepX) {
                            Text("Read")
                                .font(.caption)
                            ReadReceiptAvatarsView(members: group.readByMembers)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Tap to see who read this message")
                } else {
                    Text("Sent")
                        .font(.caption)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.colorFillTertiary)
                        .frame(width: 16, height: 16)
                }
            }
            .transition(.blurReplace)
            .padding(.vertical, DesignConstants.Spacing.stepX)
            .padding(.leading, DesignConstants.Spacing.step2x)
            .padding(.trailing, DesignConstants.Spacing.step4x)
            .foregroundStyle(.colorTextSecondary)
            .zIndex(-1)
            .id("sent-status-\(message.differenceIdentifier)")
            .accessibilityLabel(
                group.onlyVisibleToSender
                    ? "Only visible to you"
                    : (group.readByMembers.isEmpty
                        ? "Message sent"
                        : "Message read by \(group.readByMembers.count) \(group.readByMembers.count == 1 ? "member" : "members")")
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            if let card = group.assistantContactCard {
                senderLabel
                contactCardRow(card: card)
                if let descriptor = group.contactCardThinkingDescriptor {
                    contactCardThinkingFooterRow(descriptor: descriptor)
                }
            }

            ForEach(Array(group.allMessages.enumerated()), id: \.element.messageId) { index, message in
                messageGroup(index: index, message: message)
            }

            if group.showsTypingIndicator {
                if group.isMultiTyper {
                    multiTyperIndicator
                } else {
                    singleTyperIndicator
                }
            }

            if group.showsThinkingIndicator {
                thinkingIndicator
            }
        }
        .id("message-group-container-\(group.id)")
        .transition(
            .asymmetric(
                insertion: .identity,
                removal: .opacity
            )
        )
        .padding(.top, group.adjacentToFullBleedAbove ? (1.0 / displayScale) : DesignConstants.Spacing.step2x)
        .padding(.bottom, group.adjacentToFullBleedBelow ? (1.0 / displayScale) : DesignConstants.Spacing.step2x)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: group)
        .onAppear {
            guard isAppearing, !hasAnimated else { return }
            hasAnimated = true

            if animates {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isAppearing = false
                }
            } else {
                withAnimation(.none) {
                    isAppearing = false
                }
            }
        }
        .id("messages-group-\(group.id)")
    }
}

/// Caption used in the merged thinking + read-receipt row. Mirrors
/// `ThinkingIndicatorFooterView`'s pulse cadence (0.5 ↔ 1.0 over 1.2s,
/// matching `AssistantContactCardView.PulsingSubtitle`). When other
/// members have already read the message, the assistant avatar lives in
/// the trailing avatars list so this caption only shows text + chevron.
/// When the assistant is the only "reader", the avatar moves to the
/// leading edge of this caption — there's no avatars list on the
/// trailing side, so leading the indicator makes "who is thinking"
/// obvious without dangling avatar chrome to its right. The whole row
/// (avatar + text + chevron) shares the pulse envelope in that case.
private struct MergedThinkingCaption: View {
    let descriptor: ThinkingSessionDescriptor
    var showsLeadingAvatar: Bool = false
    @State private var isPulsed: Bool = false

    private var isResolved: Bool {
        !descriptor.isActive
    }

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            if showsLeadingAvatar {
                MessageAvatarView(
                    profile: descriptor.sender.profile,
                    size: DesignConstants.ImageSizes.extraSmallAvatar,
                    agentVerification: descriptor.sender.agentVerification
                )
            }
            Text(descriptor.content)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.colorTextTertiary)
        }
        .opacity(isResolved ? 1.0 : (isPulsed ? 0.5 : 1.0))
        .animation(
            isResolved ? .default : .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
            value: isPulsed
        )
        .onAppear { isPulsed = !isResolved }
    }
}

/// SwiftUI-side analogue of `MessagesGroupItemView`'s `@State`-driven
/// appearance animation, applied to `ThoughtBubble` rows in
/// `ThinkingDetailView`. The detail view runs every moment through a single
/// `MessagesGroup` cell, so the collection-view layout never sees per-moment
/// insertions and can't drive the chat's cell-level slide-up. Each row
/// instead owns its own appearance state: on first `onAppear` it animates
/// from a folded-in pose (scaled, offset down, faded) to settled. Only the
/// newest moment (`origin == .inserted`) actually animates — earlier
/// moments flip straight to settled with `.none`, matching how
/// `MessagesGroupItemView` gates its own animation.
private struct ThoughtBubbleAppearance<Content: View>: View {
    let animates: Bool
    @ViewBuilder let content: () -> Content
    @State private var isAppearing: Bool = true
    @State private var hasAnimated: Bool = false

    var body: some View {
        content()
            .scaleEffect(isAppearing ? 0.8 : 1.0, anchor: .bottomLeading)
            .opacity(isAppearing ? 0.0 : 1.0)
            .offset(y: isAppearing ? 40 : 0)
            .onAppear {
                guard isAppearing, !hasAnimated else { return }
                hasAnimated = true
                if animates {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isAppearing = false
                    }
                } else {
                    withAnimation(.none) {
                        isAppearing = false
                    }
                }
            }
    }
}

#Preview("All Message Permutations") {
    let alice = ConversationMember.mock(isCurrentUser: false, name: "Alice")
    let me = ConversationMember.mock(isCurrentUser: true)
    let reactions: [MessageReaction] = [
        .mock(emoji: "❤️", sender: .mock(isCurrentUser: true)),
        .mock(emoji: "😂", sender: .mock(isCurrentUser: false, name: "Bob")),
    ]
    let photoURL = "https://picsum.photos/400/300"
    let photoAttachment = HydratedAttachment(key: photoURL, width: 400, height: 300)
    let hiddenPhoto = HydratedAttachment(key: photoURL, isHiddenByOwner: true, width: 400, height: 300)

    let groups: [MessagesGroup] = [
        // -- Text messages --
        MessagesGroup(
            id: "text-incoming",
            sender: alice,
            messages: [
                .message(Message.mock(text: "Standard text message", sender: alice), .existing),
                .message(Message.mock(text: "With reactions", sender: alice, reactions: reactions), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "text-outgoing",
            sender: me,
            messages: [
                .message(Message.mock(text: "Standard text message", sender: me), .existing),
                .message(Message.mock(text: "With reactions", sender: me, reactions: reactions), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Emoji messages --
        MessagesGroup(
            id: "emoji-incoming",
            sender: alice,
            messages: [
                .message(Message.mock(text: "🔥", sender: alice), .existing),
                .message(Message.mock(text: "🎉", sender: alice, reactions: reactions), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "emoji-outgoing",
            sender: me,
            messages: [
                .message(Message.mock(text: "❤️", sender: me), .existing),
                .message(Message.mock(text: "🙌", sender: me, reactions: reactions), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Photo messages --
        MessagesGroup(
            id: "photo-incoming",
            sender: alice,
            messages: [
                .message(Message.mock(content: .attachment(photoAttachment), sender: alice), .existing),
                .message(Message.mock(content: .attachment(photoAttachment), sender: alice, reactions: reactions), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "photo-outgoing",
            sender: me,
            messages: [
                .message(Message.mock(content: .attachment(photoAttachment), sender: me), .existing),
                .message(Message.mock(content: .attachment(photoAttachment), sender: me, reactions: reactions), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Hidden/blurred photos --
        MessagesGroup(
            id: "photo-hidden",
            sender: alice,
            messages: [
                .message(Message.mock(content: .attachment(hiddenPhoto), sender: alice), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Link messages --
        MessagesGroup(
            id: "link-incoming",
            sender: alice,
            messages: [
                .message(Message.mock(text: "Check out https://convos.org", sender: alice), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "link-outgoing",
            sender: me,
            messages: [
                .message(Message.mock(text: "Look at this https://github.com/xmtplabs/convos-ios", sender: me), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Invite messages --
        MessagesGroup(
            id: "invite-incoming",
            sender: alice,
            messages: [
                .message(Message.mock(content: .invite(.mock), sender: alice), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "invite-outgoing",
            sender: me,
            messages: [
                .message(Message.mock(content: .invite(.mock), sender: me), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Text reply to text --
        MessagesGroup(
            id: "reply-text-to-text",
            sender: alice,
            messages: [
                .reply(MessageReply.mock(
                    text: "Totally agree!",
                    sender: alice,
                    parentText: "What do you think about the new design?",
                    parentSender: me
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "reply-text-to-text-out",
            sender: me,
            messages: [
                .reply(MessageReply.mock(
                    text: "Sounds good to me",
                    sender: me,
                    parentText: "Let's meet at 3pm tomorrow",
                    parentSender: alice
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Text reply to photo --
        MessagesGroup(
            id: "reply-text-to-photo",
            sender: alice,
            messages: [
                .reply(MessageReply.mock(
                    text: "Great photo!",
                    sender: alice,
                    parentContent: .attachment(photoAttachment),
                    parentSender: me
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "reply-text-to-photo-out",
            sender: me,
            messages: [
                .reply(MessageReply.mock(
                    text: "Love this shot",
                    sender: me,
                    parentContent: .attachment(photoAttachment),
                    parentSender: alice
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Text reply to emoji --
        MessagesGroup(
            id: "reply-text-to-emoji",
            sender: alice,
            messages: [
                .reply(MessageReply.mock(
                    text: "Haha same!",
                    sender: alice,
                    parentContent: .emoji("🔥"),
                    parentSender: me
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "reply-text-to-emoji-out",
            sender: me,
            messages: [
                .reply(MessageReply.mock(
                    text: "Right back at you",
                    sender: me,
                    parentContent: .emoji("❤️"),
                    parentSender: alice
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Text reply to invite --
        MessagesGroup(
            id: "reply-text-to-invite",
            sender: alice,
            messages: [
                .reply(MessageReply.mock(
                    text: "I'll join!",
                    sender: alice,
                    parentContent: .invite(.mock),
                    parentSender: me
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Photo reply to text --
        MessagesGroup(
            id: "reply-photo-to-text",
            sender: alice,
            messages: [
                .reply(MessageReply.mock(
                    sender: alice,
                    replyContent: .attachment(photoAttachment),
                    parentText: "Show me what you mean",
                    parentSender: me
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "reply-photo-to-text-out",
            sender: me,
            messages: [
                .reply(MessageReply.mock(
                    sender: me,
                    replyContent: .attachment(photoAttachment),
                    parentText: "Can you send a pic?",
                    parentSender: alice
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Photo reply to photo --
        MessagesGroup(
            id: "reply-photo-to-photo",
            sender: alice,
            messages: [
                .reply(MessageReply.mock(
                    sender: alice,
                    replyContent: .attachment(photoAttachment),
                    parentContent: .attachment(photoAttachment),
                    parentSender: me
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Photo reply to emoji --
        MessagesGroup(
            id: "reply-photo-to-emoji",
            sender: me,
            messages: [
                .reply(MessageReply.mock(
                    sender: me,
                    replyContent: .attachment(photoAttachment),
                    parentContent: .emoji("🙌"),
                    parentSender: alice
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Photo reply to invite --
        MessagesGroup(
            id: "reply-photo-to-invite",
            sender: me,
            messages: [
                .reply(MessageReply.mock(
                    sender: me,
                    replyContent: .attachment(photoAttachment),
                    parentContent: .invite(.mock),
                    parentSender: alice
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Reactions on replies --
        MessagesGroup(
            id: "reply-with-reactions",
            sender: alice,
            messages: [
                .reply(MessageReply.mock(
                    text: "Love it!",
                    sender: alice,
                    parentText: "Check out this idea",
                    parentSender: me,
                    reactions: reactions
                ), .existing),
                .reply(MessageReply.mock(
                    sender: alice,
                    replyContent: .attachment(photoAttachment),
                    parentText: "Send me a photo",
                    parentSender: me,
                    reactions: reactions
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Sent status --
        MessagesGroup(
            id: "sent-status",
            sender: me,
            messages: [
                .message(Message.mock(text: "Last message with sent status", sender: me), .existing),
            ],
            isLastGroup: true,
            isLastGroupSentByCurrentUser: true
        ),

        // -- Failed message --
        MessagesGroup(
            id: "failed-message",
            sender: me,
            messages: [
                .message(Message.mock(text: "This message failed to send", sender: me, status: .failed), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
    ]

    ScrollView {
        VStack(spacing: 0) {
            ForEach(groups) { group in
                MessagesGroupView(
                    group: group,
                    conversationId: "preview-conversation",
                    shouldBlurPhotos: true,
                    onTapAvatar: { _ in },
                    onTapInvite: { _ in },
                    onTapReactions: { _ in },
                    onReaction: { _, _ in },
                    onToggleReaction: { _, _ in },
                    onReply: { _ in },
                    onPhotoRevealed: { _ in },
                    onPhotoHidden: { _ in },
                    onPhotoDimensionsLoaded: { _, _, _ in }
                )
            }
        }
    }
    .background(.colorBackgroundSurfaceless)
}
