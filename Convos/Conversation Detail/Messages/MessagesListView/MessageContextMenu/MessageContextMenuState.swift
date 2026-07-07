import ConvosCore
import SwiftUI

@Observable
class MessageContextMenuState: @unchecked Sendable {
    var presentedMessage: AnyMessage?
    var bubbleFrame: CGRect = .zero
    var isOutgoing: Bool = false
    var bubbleStyle: MessageBubbleType = .normal
    var isReplyParent: Bool = false
    /// Whether the source bubble's long-body inline expansion was on when the
    /// menu opened, so the preview matches what's on screen (full text when
    /// expanded, bounded teaser when collapsed). Owned by the conversation view
    /// model and captured at present time, mirroring the on-screen bubble's
    /// `isExpanded`.
    var isExpanded: Bool = false
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

    func present(message: AnyMessage, bubbleFrame: CGRect, bubbleStyle: MessageBubbleType, isExpanded: Bool) {
        self.isOutgoing = message.sender.isCurrentUser
        self.bubbleFrame = bubbleFrame
        self.bubbleStyle = bubbleStyle
        self.isReplyParent = false
        self.isExpanded = isExpanded
        self.presentedMessage = message
    }

    func presentReplyParent(message: AnyMessage, bubbleFrame: CGRect, sourceID: UUID) {
        self.isOutgoing = message.sender.isCurrentUser
        self.bubbleFrame = bubbleFrame
        self.bubbleStyle = .normal
        self.isReplyParent = true
        self.isExpanded = false
        self.sourceID = sourceID
        self.presentedMessage = message
    }

    func dismiss() {
        presentedMessage = nil
        isReplyParent = false
        isExpanded = false
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
