import ConvosCore
import ConvosLogging
import SwiftUI

struct MessagesGroupView: View {
    let group: MessagesGroup
    let conversationId: String
    let onTapAvatar: (AnyMessage) -> Void
    /// Fires when the sender label or an avatar that has no concrete message
    /// to attach (e.g. the synthesized agent contact-card group) is
    /// tapped. Routes to the same profile sheet `onTapAvatar` does, just
    /// without needing an `AnyMessage`. Defaults to a no-op so the preview /
    /// dead-code SwiftUI list don't have to wire it.
    var onTapSender: (ConversationMember) -> Void = { _ in }
    let onTapInvite: (MessageInvite) -> Void
    let onTapReactions: (AnyMessage) -> Void
    var onTapReadReceipts: ((MessagesGroup) -> Void)?
    var onTapThinkingIndicator: ((ThinkingSessionDescriptor) -> Void)?
    let onReaction: (String, String) -> Void
    let onToggleReaction: (String, String) -> Void
    let onReply: (AnyMessage) -> Void
    /// Surfaces a pathological text bubble's "Read More" tap to the host so it
    /// can present `MessageDetailView`. nil outside the main messages list path.
    var onOpenMessageDetail: ((AnyMessage) -> Void)?
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    var onOpenFile: ((HydratedAttachment, AnyMessage) -> Void)?
    var onRetryMessage: ((AnyMessage) -> Void)?
    var onDeleteMessage: ((AnyMessage) -> Void)?
    var onRetryTranscript: ((VoiceMemoTranscriptListItem) -> Void)?
    var allVoiceMemoTranscripts: [String: VoiceMemoTranscriptListItem] = [:]
    /// Threaded through to `HTMLAttachmentBubble`'s
    /// `.matchedTransitionSource(...)` so the bubble pairs with the
    /// `AttachmentPreviewSheet` zoom transition. nil outside the main
    /// messages list path.
    var htmlAttachmentTransitionNamespace: Namespace.ID?
    /// Mirrors `ConversationViewModel.creditsDepleted`. Drives the inline
    /// `bolt.fill` glyph next to an agent sender's display name when
    /// the global credit balance is depleted.
    var creditsDepleted: Bool = false

    @Environment(\.displayScale) private var displayScale: CGFloat
    @State private var isAppearing: Bool = true
    @State private var hasAnimated: Bool = false
    /// Animated mirror of `group.readByMembers` for the status row. Cell
    /// reconfigures evaluate this view in a sizing pass before the render
    /// pass, which consumes value-based `.animation(value:)` triggers, so
    /// the Sent -> Read swap would render without animation. Mutating this
    /// mirror inside `withAnimation` from `onChange` creates a fresh
    /// transaction that survives the two-pass update and drives the
    /// `.blurReplace` morph. nil until the first change so the initial
    /// render falls through to the live value without a flash.
    @State private var animatedReadByMembers: [ConversationMember]?
    /// Animated mirror of the whole `group`, same mechanism as
    /// `animatedReadByMembers` but covering every within-group change: a
    /// sent message appending to the group, the status caption moving to
    /// the new last message, reactions, etc. The sizing pass renders the
    /// old mirror value (so the cell reports its old height and the batch
    /// update applies no instant offset jump), then `onChange` mutates the
    /// mirror inside `withAnimation`, animating the content and height
    /// through self-sizing invalidation. nil until the first change so the
    /// initial render uses the live value.
    @State private var animatedGroup: MessagesGroup?

    /// The group value the body renders: the animated mirror once seeded,
    /// the live configuration value before that.
    private var displayGroup: MessagesGroup { animatedGroup ?? group }

    private var animates: Bool {
        displayGroup.messages.first?.origin == .inserted
    }

    private var avatarWidth: CGFloat {
        displayGroup.sender.isCurrentUser ? 0 : DesignConstants.ImageSizes.smallAvatar + DesignConstants.Spacing.step2x
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
            .foregroundColor(displayGroup.sender.isAgent ? displayGroup.sender.agentVerification.nameColor : .secondary)
            .padding(.leading, avatarWidth + DesignConstants.Spacing.step4x + DesignConstants.Spacing.step3x)
            .padding(.bottom, DesignConstants.Spacing.stepHalf)
    }

    private var senderLabelContent: some View {
        let tapAction = { onTapSender(displayGroup.sender) }
        return Button(action: tapAction) {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Text(displayGroup.sender.profile.displayName)
                if displayGroup.sender.isAgent && creditsDepleted {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.colorLava)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func avatarOverlay(onTap: (() -> Void)? = nil) -> some View {
        MessageAvatarView(profile: displayGroup.sender.profile, size: avatarSize, agentVerification: displayGroup.sender.agentVerification)
            .offset(x: -(avatarSize + avatarSpacing))
            .onTapGesture { onTap?() }
            .scaleEffect(isAppearing ? 0.9 : 1.0)
            .opacity(isAppearing ? 0.0 : 1.0)
            .offset(
                x: isAppearing ? -80 : 0,
                y: 0.0
            )
            .id("profile-\(displayGroup.id)")
            .accessibilityLabel("View \(displayGroup.sender.profile.displayName)'s profile")
            .accessibilityAddTraits(.isButton)
    }

    private var singleTyperIndicator: some View {
        // The contact-card section already renders the sender label above
        // the card, so a typing-only card group must not add a second one.
        let isTypingOnly = displayGroup.allMessages.isEmpty && displayGroup.agentContactCard == nil

        return Group {
            if isTypingOnly && !displayGroup.sender.isCurrentUser {
                senderLabel
            }

            HStack(alignment: .bottom, spacing: avatarSpacing) {
                if !displayGroup.sender.isCurrentUser {
                    Color.clear
                        .frame(width: avatarSize, height: avatarSize)
                }

                TypingIndicatorBubbleView(senderName: displayGroup.sender.profile.displayName)
                    .overlay(alignment: .bottomLeading) {
                        if !displayGroup.sender.isCurrentUser {
                            avatarOverlay()
                        }
                    }
            }
            .padding(.leading, !displayGroup.sender.isCurrentUser ? DesignConstants.Spacing.step4x : 0)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))
        .id("typing-indicator-\(displayGroup.id)")
    }

    private var thinkingIndicator: some View {
        HStack(alignment: .bottom, spacing: avatarSpacing) {
            if !displayGroup.sender.isCurrentUser {
                Color.clear
                    .frame(width: avatarSize, height: avatarSize)
            }

            ThinkingIndicatorBubbleView(
                content: displayGroup.thinkingContent ?? "",
                senderName: displayGroup.sender.profile.displayName,
                hidesContent: true
            )
            .overlay(alignment: .bottomLeading) {
                if !displayGroup.sender.isCurrentUser {
                    avatarOverlay()
                }
            }
        }
        .padding(.leading, !displayGroup.sender.isCurrentUser ? DesignConstants.Spacing.step4x : 0)
        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))
        .id("thinking-indicator-bubble-\(displayGroup.id)")
    }

    private var multiTyperIndicator: some View {
        let typers = displayGroup.allTypingMembers
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
        // so it can sit above the agent contact card prefix as well as the
        // first message bubble.
        if index == 0 && !displayGroup.sender.isCurrentUser && !isFullWidthAttachment && !isReply
            && displayGroup.agentContactCard == nil && !displayGroup.hidesSenderLabel {
            senderLabel
        }

        let isLastInGroup: Bool = message == displayGroup.messages.last
        // A continuation chunk follows this group in the same sender run, so
        // its visual bottom is not the end of the run -- no tail.
        let isLast: Bool = isLastInGroup && !displayGroup.showsTypingIndicator && !displayGroup.showsThinkingIndicator
            && !displayGroup.isContinuedBelow
        // When the last message is a voice memo with a transcript row attached, the
        // transcript becomes the visual bottom of the group, so the tail moves from
        // the voice memo bubble down onto the transcript row.
        let transcriptIsTailed: Bool = isLast && displayGroup.voiceMemoTranscripts[message.messageId] != nil
        let bubbleType: MessageBubbleType = (isLast && !transcriptIsTailed) ? .tailed : .normal
        // Include unpublished (optimistic) sends so the caption row's layout
        // space is reserved at append time; the row content stays invisible
        // until the message publishes (see statusRow's opacity). Inserting
        // the row only at publish allocated its space in a single frame --
        // SwiftUI transitions animate a view's appearance, not the layout
        // space it occupies -- which read as a vertical jump of the list.
        let showsSentStatus: Bool = isLastInGroup && (displayGroup.isLastGroupSentByCurrentUser || displayGroup.isLastGroupBeforeOtherMembers)
            && (message.status == .published || message.status == .unpublished)
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

        let thinkingDescriptor: ThinkingSessionDescriptor? = displayGroup.thinkingByMessageId[message.messageId]
        // Requires .published (unlike the plain status row, which reserves
        // invisible space for unpublished sends): the merged row has no
        // opacity gate, so rendering it for an optimistic message would
        // reintroduce the layout pop the reservation exists to prevent.
        let mergesThinkingIntoStatus: Bool = showsSentStatus && message.status == .published
            && thinkingDescriptor != nil && !displayGroup.onlyVisibleToSender
        if mergesThinkingIntoStatus, let descriptor = thinkingDescriptor {
            mergedThinkingStatusRow(message: message, descriptor: descriptor)
        } else {
            thinkingFooterRow(message: message)
            statusRow(message: message, isFailed: isFailed, showsSentStatus: showsSentStatus)
        }
    }

    @ViewBuilder
    private func mergedThinkingStatusRow(message: AnyMessage, descriptor: ThinkingSessionDescriptor) -> some View {
        let agent: ConversationMember = descriptor.sender
        let dedupedReaders: [ConversationMember] = displayGroup.readByMembers.filter { $0.profile.inboxId != agent.profile.inboxId }
        let hasOtherReaders: Bool = !dedupedReaders.isEmpty
        let tap: () -> Void = { onTapThinkingIndicator?(descriptor) }

        HStack(spacing: DesignConstants.Spacing.stepX) {
            Spacer()
            Button(action: tap) {
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    MergedThinkingCaption(descriptor: descriptor, showsLeadingAvatar: !hasOtherReaders)
                    if hasOtherReaders {
                        ReadReceiptAvatarsView(members: [agent] + dedupedReaders)
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
    private func contactCardRow(card: AgentContactCardInfo) -> some View {
        // The card shows its own bottom-leading avatar only when it is the
        // visual end of the agent's run: nothing else in this group below it
        // and no agent message group directly underneath. When the agent's
        // messages sit directly below, that group's avatar overlay handles
        // the leading avatar - we don't want to double up.
        let cardIsLast: Bool = displayGroup.allMessages.isEmpty
            && !displayGroup.showsTypingIndicator
            && !displayGroup.showsThinkingIndicator
            && !displayGroup.contactCardPrecedesAgentMessages
        HStack(alignment: .bottom, spacing: avatarSpacing) {
            if !displayGroup.sender.isCurrentUser {
                Color.clear
                    .frame(width: avatarSize, height: avatarSize)
            }

            let cardTap = { onTapSender(displayGroup.sender) }
            // Trailing inset matches the card's leading inset (the row's `step4x`
            // padding + the avatar gutter) so the card is centered in the view
            // rather than sitting slightly off-center. `bubbleRowWidthCap` still
            // caps + leading-pins the row on regular-width layouts.
            let trailingInset: CGFloat = DesignConstants.Spacing.step4x + avatarSize + avatarSpacing
            HStack(alignment: .bottom, spacing: 0.0) {
                AgentContactCardView(profile: card.profile, agentDescription: card.agentDescription)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: cardTap)
                    .overlay(alignment: .bottomLeading) {
                        if cardIsLast && !displayGroup.sender.isCurrentUser {
                            avatarOverlay { onTapSender(displayGroup.sender) }
                        }
                    }

                Spacer()
                    .frame(minWidth: trailingInset)
                    .layoutPriority(-1)
            }
            .bubbleRowWidthCap(alignment: .leading)
        }
        .padding(.leading, !displayGroup.sender.isCurrentUser ? DesignConstants.Spacing.step4x : 0)
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
            if !displayGroup.sender.isCurrentUser && !isFullWidthAttachment {
                Color.clear
                    .frame(width: avatarSize, height: avatarSize)
            }

            if displayGroup.usesThoughtBubbleStyle, let text = thoughtBubbleText(for: message) {
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
                .bubbleRowWidthCap(alignment: .leading)
                .zIndex(100)
                .id("messages-group-item-\(message.differenceIdentifier)")
                .overlay(alignment: .bottomLeading) {
                    if isLast && !displayGroup.sender.isCurrentUser {
                        avatarOverlay { onTapAvatar(message) }
                    }
                }
            } else {
                MessagesGroupItemView(
                    message: message,
                    conversationId: conversationId,
                    bubbleType: bubbleType,
                    onTapAvatar: onTapAvatar,
                    onTapInvite: onTapInvite,
                    onReply: onReply,
                    onOpenMessageDetail: onOpenMessageDetail,
                    onPhotoDimensionsLoaded: onPhotoDimensionsLoaded,
                    onOpenFile: onOpenFile,
                    htmlAttachmentTransitionNamespace: htmlAttachmentTransitionNamespace,
                    onTapReactions: onTapReactions,
                    onReaction: onReaction,
                    onToggleReaction: onToggleReaction,
                    voiceMemoTranscript: displayGroup.voiceMemoTranscripts[message.messageId],
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
                    if isLast && !displayGroup.sender.isCurrentUser {
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
        .padding(.leading, !displayGroup.sender.isCurrentUser && !isFullWidthAttachment ? DesignConstants.Spacing.step4x : 0)
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
        // Reactions render from the live group, not the animatedGroup
        // mirror: with live data the row's height change is measured during
        // the reconfigure's sizing pass and lands inside the batch update,
        // where UIKit animates the surrounding cells and the bottom-pinning
        // compensation natively (the smooth pre-existing behavior). Routing
        // it through the mirror would move the growth out of the batch into
        // the out-of-band reveal path that exists for message appends.
        let liveReactions: [MessageReaction] = group.rawMessages
            .first(where: { $0.messageId == message.messageId })?.reactions ?? message.reactions
        if !liveReactions.isEmpty, !isFullWidthAttachment {
            ReactionIndicatorView(
                reactions: liveReactions,
                isOutgoing: message.sender.isCurrentUser,
                onTap: { onTapReactions(message) }
            )
            .padding(.leading, message.sender.isCurrentUser ? 0 : avatarWidth + avatarSpacing + DesignConstants.Spacing.step2x)
            .padding(.trailing, message.sender.isCurrentUser ? DesignConstants.Spacing.step4x : 0)
            .padding(.bottom, DesignConstants.Spacing.stepX)
            .transition(.identity)
            .zIndex(50)
            .id("reactions-\(message.differenceIdentifier)")
        }
    }

    /// Inline thinking footer anchored to the contact card (not to a
    /// specific message). The card row above already shows the agent
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
        if let descriptor = displayGroup.thinkingByMessageId[message.messageId] {
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
            let readByMembers: [ConversationMember] = animatedReadByMembers ?? group.readByMembers
            // Reserve the row's layout space while the message is still
            // unpublished but keep it invisible; publishing fades it in
            // without shifting the list (see showsSentStatus).
            let statusOpacity: Double = message.status == .published ? 1 : 0
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Spacer()
                if displayGroup.onlyVisibleToSender {
                    Text("Only visible to you")
                        .font(.caption)
                    ProfileAvatarView(
                        profile: displayGroup.sender.profile,
                        profileImage: ProfileSettingsViewModel.shared.profileImage,
                        useSystemPlaceholder: false
                    )
                    .frame(width: 16, height: 16)
                } else if !readByMembers.isEmpty {
                    let readReceiptTap: () -> Void = { onTapReadReceipts?(group) }
                    Button(action: readReceiptTap) {
                        HStack(spacing: DesignConstants.Spacing.stepX) {
                            Text("Read")
                                .font(.caption)
                            ReadReceiptAvatarsView(members: readByMembers)
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
            .opacity(statusOpacity)
            .animation(.easeInOut(duration: 0.2), value: statusOpacity)
            .transition(.blurReplace)
            .padding(.vertical, DesignConstants.Spacing.stepX)
            .padding(.leading, DesignConstants.Spacing.step2x)
            .padding(.trailing, DesignConstants.Spacing.step4x)
            .foregroundStyle(.colorTextSecondary)
            .zIndex(-1)
            .id("sent-status-\(message.differenceIdentifier)")
            .accessibilityLabel(
                displayGroup.onlyVisibleToSender
                    ? "Only visible to you"
                    : (readByMembers.isEmpty
                        ? "Message sent"
                        : "Message read by \(readByMembers.count) \(readByMembers.count == 1 ? "member" : "members")")
            )
            .accessibilityHidden(message.status != .published)
            .onAppear {
                if animatedReadByMembers == nil {
                    animatedReadByMembers = group.readByMembers
                }
            }
            .onChange(of: group.readByMembers) { _, newValue in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    animatedReadByMembers = newValue
                }
            }
        }
    }

    /// Seam padding between split chunks of one sender run matches the
    /// in-group bubble spacing (`stepX`, half on each side of the seam) so
    /// the split is invisible.
    private var groupTopPadding: CGFloat {
        if displayGroup.continuesPreviousGroup {
            return DesignConstants.Spacing.stepX / 2
        }
        return displayGroup.adjacentToFullBleedAbove ? (1.0 / displayScale) : DesignConstants.Spacing.step2x
    }

    private var groupBottomPadding: CGFloat {
        if displayGroup.isContinuedBelow {
            return DesignConstants.Spacing.stepX / 2
        }
        return displayGroup.adjacentToFullBleedBelow ? (1.0 / displayScale) : DesignConstants.Spacing.step2x
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            if let card = displayGroup.agentContactCard {
                senderLabel
                contactCardRow(card: card)
                if let descriptor = displayGroup.contactCardThinkingDescriptor {
                    contactCardThinkingFooterRow(descriptor: descriptor)
                }
            }

            ForEach(Array(displayGroup.allMessages.enumerated()), id: \.element.messageId) { index, message in
                messageGroup(index: index, message: message)
            }

            if displayGroup.showsTypingIndicator {
                if displayGroup.isMultiTyper {
                    multiTyperIndicator
                } else {
                    singleTyperIndicator
                }
            }

            if displayGroup.showsThinkingIndicator {
                thinkingIndicator
            }
        }
        .id("message-group-container-\(displayGroup.id)")
        .transition(
            .asymmetric(
                insertion: .identity,
                removal: .opacity
            )
        )
        .padding(.top, groupTopPadding)
        .padding(.bottom, groupBottomPadding)
        // Apply group changes through the mirror without animating layout:
        // the mirror only updates in `onChange` -- after the reconfigure's
        // sizing pass -- so the cell reports its old height during the batch
        // update and the new content lands below the fold unanimated (no
        // single-frame jump, no transient re-centering while the cell frame
        // snaps). The view controller then reveals the appended content
        // with an animated scroll-to-bottom. Height-neutral changes that
        // should still animate (read receipts, the status caption fade)
        // carry their own scoped animations.
        .onChange(of: group) { _, newValue in
            animatedGroup = newValue
        }
        // Snap the read-receipt mirror without animation when the status row
        // moves to a different message (a new send) so the fresh row starts
        // from "Sent" instead of morphing out of the previous message's
        // "Read" state.
        .onChange(of: group.messages.last?.messageId) { _, _ in
            animatedReadByMembers = group.readByMembers
        }
        .onAppear {
            if animatedGroup == nil {
                animatedGroup = group
            }
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
        .id("messages-group-\(displayGroup.id)")
    }
}

/// Caption used in the merged thinking + read-receipt row. Mirrors
/// `ThinkingIndicatorFooterView`'s pulse cadence (0.5 ↔ 1.0 over 1.2s,
/// matching `AgentContactCardView.PulsingSubtitle`). When other
/// members have already read the message, the agent avatar lives in
/// the trailing avatars list so this caption only shows text + chevron.
/// When the agent is the only "reader", the avatar moves to the
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
    let hiddenPhoto = HydratedAttachment(key: photoURL, width: 400, height: 300)

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
                    onTapAvatar: { _ in },
                    onTapInvite: { _ in },
                    onTapReactions: { _ in },
                    onReaction: { _, _ in },
                    onToggleReaction: { _, _ in },
                    onReply: { _ in },
                    onPhotoDimensionsLoaded: { _, _, _ in }
                )
            }
        }
    }
    .background(.colorBackgroundSurfaceless)
}
