import Foundation

public struct MessagesGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let sender: ConversationMember
    public let rawMessages: ArraySlice<AnyMessage>
    public let isLastGroup: Bool
    public var isLastGroupSentByCurrentUser: Bool
    public let showsTypingIndicator: Bool
    public let allTypingMembers: [ConversationMember]
    public let readByMembers: [ConversationMember]
    public var onlyVisibleToSender: Bool = false
    public var isLastGroupBeforeOtherMembers: Bool = false
    public var adjacentToFullBleedAbove: Bool = false
    public var adjacentToFullBleedBelow: Bool = false
    /// Display-time transcript rows keyed by parent message id. Populated by
    /// `MessagesListProcessor` when it builds the group, so changes to the
    /// transcript state propagate through the existing diffing reload pipeline.
    public var voiceMemoTranscripts: [String: VoiceMemoTranscriptListItem] = [:]
    /// When non-nil, renders the agent "contact card" (avatar + display
    /// name + `description` subtitle) as the first item of this group. The
    /// surrounding `MessagesGroupView` reuses its existing sender-label and
    /// leading-avatar slots so the card doesn't have to duplicate them.
    public var agentContactCard: AgentContactCardInfo?
    /// Active `convos.org/thinking:1.0` sessions whose `targetMessageId`
    /// matches a message in this group, keyed by that message id. The view
    /// renders an inline footer (read-receipt-style) under each anchored
    /// message; the standalone bubble is reserved for the detail sheet.
    public var thinkingByMessageId: [String: ThinkingSessionDescriptor] = [:]
    /// Suppresses the sender label that `MessagesGroupView` would otherwise
    /// render above an incoming group's first message. Hosts where the
    /// surrounding chrome already identifies the sender (e.g. the thinking
    /// detail sheet's pill) set this to true to avoid the redundant label.
    public var hidesSenderLabel: Bool = false
    /// True when this group is a continuation chunk of a longer same-sender
    /// run that `MessagesListProcessor` split for layout performance (one
    /// giant cell would otherwise build and measure dozens of bubbles at
    /// once). The view hides the sender label and tightens the top seam so
    /// the split is invisible.
    public var continuesPreviousGroup: Bool = false
    /// True when a continuation chunk follows this group in the same
    /// same-sender run. The view suppresses the bubble tail on the last
    /// message and tightens the bottom seam.
    public var isContinuedBelow: Bool = false
    /// When true, the group renders a trailing pulsing-dot thinking bubble
    /// after its messages — visually the bottom-most item of the run, so
    /// `MessagesGroupView`'s avatar overlay attaches to the bubble instead
    /// of to the last regular message. Drives the thinking-detail timeline:
    /// every prior `start` moment shows as a text bubble; the bubble itself
    /// is the "still working" cap.
    public var showsThinkingIndicator: Bool = false
    /// Optional caption text rendered under the trailing thinking bubble.
    /// Today the thinking detail surfaces the latest moment as its own text
    /// cell above the bubble, so this stays nil — but kept on the model so
    /// future hosts (e.g. a conversation-view inline thinking trailing
    /// bubble) can opt into the caption without another schema change.
    public var thinkingContent: String?
    /// When true, text messages in this group render with `ThoughtBubble`
    /// (rounded rect with two trailing tail circles, secondary text color)
    /// instead of the regular `MessageContainer` chat bubble. Set by the
    /// thinking detail processor so the moments read as the agent's
    /// internal monologue rather than chat messages.
    public var usesThoughtBubbleStyle: Bool = false
    /// When non-nil and `agentContactCard != nil`, renders an inline
    /// thinking footer immediately below the contact card. Set by the
    /// view-model layer when the agent has a thinking session whose
    /// `targetMessageId` is a build-flow user prompt — either still
    /// visible (pre-Make) or filtered out by the builder summary cutoff
    /// (post-Make). The card is the canonical anchor for "the agent
    /// is thinking about your build input".
    public var contactCardThinkingDescriptor: ThinkingSessionDescriptor?
    /// True when this synthesized contact-card row is immediately followed
    /// by a message group from the same agent. The card defers its
    /// bottom-leading avatar to that group's last message (and the group
    /// below hides its duplicate sender label) so the pair reads as one
    /// visual run.
    public var contactCardPrecedesAgentMessages: Bool = false

    public var isMultiTyper: Bool {
        allTypingMembers.count > 1
    }

    public var isFullBleedAttachment: Bool {
        rawMessages.count == 1 && rawMessages.first?.content.isFullBleedAttachment == true
    }

    public var messages: RebasedSlice<AnyMessage> {
        RebasedSlice(rawMessages)
    }

    public var allMessages: RebasedSlice<AnyMessage> {
        messages
    }

    public init(
        id: String,
        sender: ConversationMember,
        messages: ArraySlice<AnyMessage>,
        isLastGroup: Bool,
        isLastGroupSentByCurrentUser: Bool,
        showsTypingIndicator: Bool = false,
        allTypingMembers: [ConversationMember] = [],
        readByMembers: [ConversationMember] = [],
        onlyVisibleToSender: Bool = false,
        isLastGroupBeforeOtherMembers: Bool = false,
        voiceMemoTranscripts: [String: VoiceMemoTranscriptListItem] = [:]
    ) {
        self.id = id
        self.sender = sender
        self.rawMessages = messages
        self.isLastGroup = isLastGroup
        self.isLastGroupSentByCurrentUser = isLastGroupSentByCurrentUser
        self.showsTypingIndicator = showsTypingIndicator
        self.allTypingMembers = allTypingMembers
        self.readByMembers = readByMembers
        self.onlyVisibleToSender = onlyVisibleToSender
        self.isLastGroupBeforeOtherMembers = isLastGroupBeforeOtherMembers
        self.voiceMemoTranscripts = voiceMemoTranscripts
    }

    public init(
        id: String,
        sender: ConversationMember,
        messages: [AnyMessage],
        isLastGroup: Bool,
        isLastGroupSentByCurrentUser: Bool,
        showsTypingIndicator: Bool = false,
        allTypingMembers: [ConversationMember] = [],
        readByMembers: [ConversationMember] = [],
        onlyVisibleToSender: Bool = false,
        isLastGroupBeforeOtherMembers: Bool = false,
        voiceMemoTranscripts: [String: VoiceMemoTranscriptListItem] = [:]
    ) {
        self.id = id
        self.sender = sender
        self.rawMessages = messages[...]
        self.isLastGroup = isLastGroup
        self.isLastGroupSentByCurrentUser = isLastGroupSentByCurrentUser
        self.showsTypingIndicator = showsTypingIndicator
        self.allTypingMembers = allTypingMembers
        self.readByMembers = readByMembers
        self.onlyVisibleToSender = onlyVisibleToSender
        self.isLastGroupBeforeOtherMembers = isLastGroupBeforeOtherMembers
        self.voiceMemoTranscripts = voiceMemoTranscripts
    }

    public static func == (lhs: MessagesGroup, rhs: MessagesGroup) -> Bool {
        lhs.id == rhs.id &&
        lhs.sender == rhs.sender &&
        lhs.rawMessages == rhs.rawMessages &&
        lhs.isLastGroup == rhs.isLastGroup &&
        lhs.isLastGroupSentByCurrentUser == rhs.isLastGroupSentByCurrentUser &&
        lhs.showsTypingIndicator == rhs.showsTypingIndicator &&
        lhs.allTypingMembers == rhs.allTypingMembers &&
        lhs.readByMembers == rhs.readByMembers &&
        lhs.onlyVisibleToSender == rhs.onlyVisibleToSender &&
        lhs.isLastGroupBeforeOtherMembers == rhs.isLastGroupBeforeOtherMembers &&
        lhs.adjacentToFullBleedAbove == rhs.adjacentToFullBleedAbove &&
        lhs.adjacentToFullBleedBelow == rhs.adjacentToFullBleedBelow &&
        lhs.voiceMemoTranscripts == rhs.voiceMemoTranscripts &&
        lhs.agentContactCard == rhs.agentContactCard &&
        lhs.thinkingByMessageId == rhs.thinkingByMessageId &&
        lhs.hidesSenderLabel == rhs.hidesSenderLabel &&
        lhs.continuesPreviousGroup == rhs.continuesPreviousGroup &&
        lhs.isContinuedBelow == rhs.isContinuedBelow &&
        lhs.showsThinkingIndicator == rhs.showsThinkingIndicator &&
        lhs.thinkingContent == rhs.thinkingContent &&
        lhs.usesThoughtBubbleStyle == rhs.usesThoughtBubbleStyle &&
        lhs.contactCardThinkingDescriptor == rhs.contactCardThinkingDescriptor &&
        lhs.contactCardPrecedesAgentMessages == rhs.contactCardPrecedesAgentMessages
    }
}

extension MessagesGroup: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(sender)
        hasher.combine(Array(rawMessages))
        hasher.combine(isLastGroup)
        hasher.combine(isLastGroupSentByCurrentUser)
        hasher.combine(showsTypingIndicator)
        hasher.combine(allTypingMembers)
        hasher.combine(readByMembers)
        hasher.combine(onlyVisibleToSender)
        hasher.combine(isLastGroupBeforeOtherMembers)
        hasher.combine(adjacentToFullBleedAbove)
        hasher.combine(adjacentToFullBleedBelow)
        hasher.combine(voiceMemoTranscripts)
        hasher.combine(agentContactCard)
        hasher.combine(thinkingByMessageId)
        hasher.combine(hidesSenderLabel)
        hasher.combine(continuesPreviousGroup)
        hasher.combine(isContinuedBelow)
        hasher.combine(showsThinkingIndicator)
        hasher.combine(thinkingContent)
        hasher.combine(usesThoughtBubbleStyle)
        hasher.combine(contactCardThinkingDescriptor)
        hasher.combine(contactCardPrecedesAgentMessages)
    }
}

/// Display payload for a `convos.org/thinking:1.0` session attached to a
/// specific message in a `MessagesGroup`. Carries everything the inline
/// footer + the detail sheet need to render without re-querying the
/// repository.
public struct ThinkingSessionDescriptor: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let sender: ConversationMember
    public let targetMessageId: String
    /// Chronologically ascending list of every `convos.org/thinking:1.0`
    /// event the receiver has persisted for this session. The inline footer
    /// reads only the latest moment's content; the detail view iterates the
    /// whole list as the "thinking history".
    public let moments: [ThinkingMoment]
    /// First `stop.resultMessageId` along the session, copied up so the
    /// inline-footer pulse gate doesn't have to scan moments every render.
    public let resultMessageId: String?
    /// True while the session has no `stop` moment yet. Drives the pulse
    /// in `ThinkingIndicatorFooterView` and the trailing bubble in the
    /// detail sheet — independent of `resultMessageId`, so a session that
    /// stopped without a reply (interrupt, error) reads as static history
    /// rather than perpetually thinking.
    public let isActive: Bool
    /// Action of the latest `convos.org/thinking-control:1.0` event sent for
    /// this session, or nil when none was ever sent. `.stop` flips the
    /// detail sheet's stop button into a resume button.
    public let lastControlAction: ThinkingControlAction?

    /// Latest moment's content, surfaced to the inline indicator as "what's
    /// the agent doing right now".
    public var content: String { moments.last?.content ?? "" }

    public init(
        id: String,
        sender: ConversationMember,
        targetMessageId: String,
        moments: [ThinkingMoment],
        resultMessageId: String? = nil,
        isActive: Bool,
        lastControlAction: ThinkingControlAction? = nil
    ) {
        self.id = id
        self.sender = sender
        self.targetMessageId = targetMessageId
        self.moments = moments
        self.resultMessageId = resultMessageId
        self.isActive = isActive
        self.lastControlAction = lastControlAction
    }
}

/// Display-only payload threaded through `MessagesGroup.agentContactCard`
/// to render an agent contact card as the leading item of the group. The
/// `profile` reuses the group's sender profile (so the avatar + display name
/// stay consistent with what the surrounding `MessagesGroupView` already
/// shows); `agentDescription` mirrors the latest `description` metadata
/// published by the agent, or `nil` while it's still being learned.
public struct AgentContactCardInfo: Equatable, Hashable, Sendable {
    public let profile: Profile
    public let agentDescription: String?

    public init(profile: Profile, agentDescription: String?) {
        self.profile = profile
        self.agentDescription = agentDescription
    }
}

/// A zero-copy wrapper around ArraySlice that rebases indices to start at 0.
/// This allows using `slice[0]`, `slice[1]`, etc. instead of the original array's indices.
public struct RebasedSlice<Element: Sendable>: RandomAccessCollection, Sendable {
    public typealias Index = Int
    private let _slice: ArraySlice<Element>

    init(_ slice: ArraySlice<Element>) {
        self._slice = slice
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { _slice.count }
    public var count: Int { _slice.count }

    public subscript(position: Int) -> Element {
        _slice[_slice.startIndex + position]
    }

    public var first: Element? { _slice.first }
    public var last: Element? { _slice.last }
    public var isEmpty: Bool { _slice.isEmpty }

    public func index(after i: Int) -> Int { i + 1 }
    public func index(before i: Int) -> Int { i - 1 }
}

extension RebasedSlice: Equatable where Element: Equatable {
    public static func == (lhs: RebasedSlice, rhs: RebasedSlice) -> Bool {
        lhs._slice == rhs._slice
    }
}

extension RebasedSlice: Hashable where Element: Hashable {
    public func hash(into hasher: inout Hasher) {
        for element in _slice {
            hasher.combine(element)
        }
    }
}
