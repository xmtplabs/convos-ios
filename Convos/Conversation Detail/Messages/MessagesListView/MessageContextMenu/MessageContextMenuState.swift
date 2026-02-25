import ConvosCore
import SwiftUI

@Observable
class MessageContextMenuState: @unchecked Sendable {
    var presentedMessage: AnyMessage?
    var bubbleFrame: CGRect = .zero
    var isOutgoing: Bool = false
    var bubbleStyle: MessageBubbleType = .normal
    var isReplyParent: Bool = false
    var sourceID: UUID?
    var onReaction: ((String, String) -> Void)?
    var onToggleReaction: ((String, String) -> Void)?

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

    func present(message: AnyMessage, bubbleFrame: CGRect, bubbleStyle: MessageBubbleType) {
        self.isOutgoing = message.base.sender.isCurrentUser
        self.bubbleFrame = bubbleFrame
        self.bubbleStyle = bubbleStyle
        self.isReplyParent = false
        self.presentedMessage = message
    }

    func presentReplyParent(message: AnyMessage, bubbleFrame: CGRect, sourceID: UUID) {
        self.isOutgoing = message.base.sender.isCurrentUser
        self.bubbleFrame = bubbleFrame
        self.bubbleStyle = .normal
        self.isReplyParent = true
        self.sourceID = sourceID
        self.presentedMessage = message
    }

    func dismiss() {
        presentedMessage = nil
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
