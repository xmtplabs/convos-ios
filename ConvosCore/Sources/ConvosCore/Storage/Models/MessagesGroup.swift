import Foundation

public struct MessagesGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let sender: ConversationMember
    public let rawMessages: ArraySlice<AnyMessage>
    public let isLastGroup: Bool
    public var isLastGroupSentByCurrentUser: Bool
    public let showsTypingIndicator: Bool
    public let allTypingMembers: [ConversationMember]
    public var onlyVisibleToSender: Bool = false
    public var isLastGroupBeforeOtherMembers: Bool = false
    public var adjacentToFullBleedAbove: Bool = false
    public var adjacentToFullBleedBelow: Bool = false
    /// Display-time transcript rows keyed by parent message id. Populated by
    /// `MessagesListProcessor` when it builds the group, so changes to the
    /// transcript state propagate through the existing diffing reload pipeline.
    public var voiceMemoTranscripts: [String: VoiceMemoTranscriptListItem] = [:]

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
        lhs.onlyVisibleToSender == rhs.onlyVisibleToSender &&
        lhs.isLastGroupBeforeOtherMembers == rhs.isLastGroupBeforeOtherMembers &&
        lhs.adjacentToFullBleedAbove == rhs.adjacentToFullBleedAbove &&
        lhs.adjacentToFullBleedBelow == rhs.adjacentToFullBleedBelow &&
        lhs.voiceMemoTranscripts == rhs.voiceMemoTranscripts
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
        hasher.combine(onlyVisibleToSender)
        hasher.combine(isLastGroupBeforeOtherMembers)
        hasher.combine(adjacentToFullBleedAbove)
        hasher.combine(adjacentToFullBleedBelow)
        hasher.combine(voiceMemoTranscripts)
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
