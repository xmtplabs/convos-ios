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

/// The native actions exposed by the small `+` control on a message bubble.
/// The composer package owns the menu presentation; the app host decides how
/// each intent should route into group chat, Things, connections, or a side DM.
public enum MessageWorkAction: String, CaseIterable, Sendable {
    case research
    case doSomething
    case remind
    case addToThings
    case connectService
    case askAgentPrivately

    public var title: String {
        switch self {
        case .research: "Research this"
        case .doSomething: "Do something with this"
        case .remind: "Make a reminder"
        case .addToThings: "Add to Things"
        case .connectService: "Connect this to any service"
        case .askAgentPrivately: "Ask the group agent privately"
        }
    }

    public var systemImage: String {
        switch self {
        case .research: "magnifyingglass"
        case .doSomething: "arrow.up.right"
        case .remind: "clock"
        case .addToThings: "square.grid.2x2"
        case .connectService: "link.badge.plus"
        case .askAgentPrivately: "sparkles"
        }
    }
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
    /// Set by the conversation host for group chats. Cells share this state
    /// instance through their UIKit-hosted SwiftUI environment, making it a
    /// lightweight bridge that does not fork the message model.
    public var isWorkMenuEnabled: Bool = false
    public var onWorkAction: ((MessageWorkAction, AnyMessage) -> Void)?

    public var currentSourceFrame: CGRect = .zero

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
