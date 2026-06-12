import ConvosCore
import SwiftUI

/// Identifies which visual piece of a message a gesture targets. A text
/// message with an edge link renders as multiple cells (link preview card
/// plus stripped text bubble), and the context menu must present only the
/// pressed cell, with its actual content.
enum MessageBubbleSegment: Equatable {
    enum Edge: String {
        case leading, trailing
    }

    case whole
    case splitText(String)
    case splitLink(LinkPreview, Edge)
}

@Observable
class MessageContextMenuState: @unchecked Sendable {
    var presentedMessage: AnyMessage?
    var presentedSegment: MessageBubbleSegment = .whole
    var bubbleFrame: CGRect = .zero
    var isOutgoing: Bool = false
    var bubbleStyle: MessageBubbleType = .normal
    var isReplyParent: Bool = false
    var sourceID: UUID?

    var currentSourceFrame: CGRect = .zero

    var isPresented: Bool {
        presentedMessage != nil
    }

    var sourceFrameMoved: Bool {
        guard isPresented else { return false }
        let dx = abs(currentSourceFrame.minX - bubbleFrame.minX)
        let dy = abs(currentSourceFrame.minY - bubbleFrame.minY)
        return dx > 2 || dy > 2
    }

    func present(message: AnyMessage, bubbleFrame: CGRect, bubbleStyle: MessageBubbleType, segment: MessageBubbleSegment = .whole) {
        self.isOutgoing = message.sender.isCurrentUser
        self.bubbleFrame = bubbleFrame
        self.bubbleStyle = bubbleStyle
        self.isReplyParent = false
        self.presentedSegment = segment
        self.presentedMessage = message
    }

    func presentReplyParent(message: AnyMessage, bubbleFrame: CGRect, sourceID: UUID) {
        self.isOutgoing = message.sender.isCurrentUser
        self.bubbleFrame = bubbleFrame
        self.bubbleStyle = .normal
        self.isReplyParent = true
        self.sourceID = sourceID
        self.presentedSegment = .whole
        self.presentedMessage = message
    }

    func dismiss() {
        presentedMessage = nil
        presentedSegment = .whole
        isReplyParent = false
        sourceID = nil
    }
}

private struct MessageContextMenuStateKey: EnvironmentKey {
    static let defaultValue: MessageContextMenuState = .init()
}

extension EnvironmentValues {
    var messageContextMenuState: MessageContextMenuState {
        get { self[MessageContextMenuStateKey.self] }
        set { self[MessageContextMenuStateKey.self] = newValue }
    }
}
