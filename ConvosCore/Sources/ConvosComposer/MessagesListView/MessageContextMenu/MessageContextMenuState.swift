#if canImport(UIKit)
import ConvosCore
import SwiftUI

/// Identifies which visual piece of a message a gesture targets. A text
/// message with an edge link renders as multiple cells (link preview card
/// plus stripped text bubble), and the context menu must present only the
/// pressed cell, with its actual content.
public enum MessageBubbleSegment: Equatable {
    public enum Edge: String {
        case leading, trailing
    }

    case whole
    case splitText(String)
    case splitLink(LinkPreview, Edge)
}

@Observable
public class MessageContextMenuState: @unchecked Sendable {
    public init() {}

    public var presentedMessage: AnyMessage?
    public var presentedSegment: MessageBubbleSegment = .whole
    public var bubbleFrame: CGRect = .zero
    public var isOutgoing: Bool = false
    public var bubbleStyle: MessageBubbleType = .normal
    public var isReplyParent: Bool = false
    /// Whether the source bubble's long-body inline expansion was on when the
    /// menu opened, so the preview matches what's on screen (full text when
    /// expanded, bounded teaser when collapsed). Owned by the conversation view
    /// model and captured at present time, mirroring the on-screen bubble's
    /// `isExpanded`.
    public var isExpanded: Bool = false
    public var sourceID: UUID?

    /// The messages currently checked in WhatsApp-style delete selection.
    /// The values are retained so the host can perform the operation after
    /// the transcript rows disappear from the live repository.
    public private(set) var selectedMessagesById: [String: AnyMessage] = [:]

    public var isSelectingMessages: Bool {
        !selectedMessagesById.isEmpty
    }

    public var selectedMessages: [AnyMessage] {
        selectedMessagesById.values.sorted { $0.date < $1.date }
    }

    public var canDeleteSelectionForEveryone: Bool {
        !selectedMessages.isEmpty && selectedMessages.allSatisfy {
            $0.sender.isCurrentUser && $0.status == .published && $0.xmtpMessageId != nil
        }
    }

    public var currentSourceFrame: CGRect = .zero

    /// Bumped to cancel any in-flight swipe-to-reply gesture on this list's
    /// messages. Used when the conversation pager changes the active page, so a
    /// horizontal swipe that started a reply on the page being left is cancelled
    /// rather than firing a stray reply as the page changes.
    public private(set) var swipeCancellationToken: Int = 0

    /// Cancels any in-flight swipe-to-reply on this list's messages.
    public func cancelInFlightSwipe() {
        swipeCancellationToken &+= 1
    }

    public var isPresented: Bool {
        presentedMessage != nil
    }

    public var sourceFrameMoved: Bool {
        guard isPresented else { return false }
        let dx = abs(currentSourceFrame.minX - bubbleFrame.minX)
        let dy = abs(currentSourceFrame.minY - bubbleFrame.minY)
        return dx > 2 || dy > 2
    }

    public func present(message: AnyMessage, bubbleFrame: CGRect, bubbleStyle: MessageBubbleType, isExpanded: Bool, segment: MessageBubbleSegment = .whole) {
        self.isOutgoing = message.sender.isCurrentUser
        self.bubbleFrame = bubbleFrame
        self.bubbleStyle = bubbleStyle
        self.isReplyParent = false
        self.presentedSegment = segment
        self.isExpanded = isExpanded
        self.presentedMessage = message
    }

    public func presentReplyParent(message: AnyMessage, bubbleFrame: CGRect, sourceID: UUID) {
        self.isOutgoing = message.sender.isCurrentUser
        self.bubbleFrame = bubbleFrame
        self.bubbleStyle = .normal
        self.isReplyParent = true
        self.isExpanded = false
        self.sourceID = sourceID
        self.presentedSegment = .whole
        self.presentedMessage = message
    }

    public func dismiss() {
        presentedMessage = nil
        presentedSegment = .whole
        isReplyParent = false
        isExpanded = false
        sourceID = nil
    }

    public func beginMessageSelection(with message: AnyMessage) {
        selectedMessagesById = [message.messageId: message]
    }

    public func toggleMessageSelection(_ message: AnyMessage) {
        if selectedMessagesById.removeValue(forKey: message.messageId) == nil {
            selectedMessagesById[message.messageId] = message
        }
    }

    public func isMessageSelected(_ message: AnyMessage) -> Bool {
        selectedMessagesById[message.messageId] != nil
    }

    public func cancelMessageSelection() {
        selectedMessagesById.removeAll()
    }
}

private struct MessageContextMenuStateKey: EnvironmentKey {
    static let defaultValue: MessageContextMenuState = .init()
}

public extension EnvironmentValues {
    var messageContextMenuState: MessageContextMenuState {
        get { self[MessageContextMenuStateKey.self] }
        set { self[MessageContextMenuStateKey.self] = newValue }
    }
}
#endif
