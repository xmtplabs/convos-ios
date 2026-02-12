import ConvosCore
import SwiftUI

@Observable
class MessageContextMenuState: @unchecked Sendable {
    var presentedMessage: AnyMessage?
    var bubbleFrame: CGRect = .zero
    var isOutgoing: Bool = false
    var bubbleStyle: MessageBubbleType = .normal
    var onReaction: ((String, String) -> Void)?
    var onToggleReaction: ((String, String) -> Void)?

    var isPresented: Bool {
        presentedMessage != nil
    }

    func present(message: AnyMessage, bubbleFrame: CGRect, bubbleStyle: MessageBubbleType) {
        self.isOutgoing = message.base.sender.isCurrentUser
        self.bubbleFrame = bubbleFrame
        self.bubbleStyle = bubbleStyle
        self.presentedMessage = message
    }

    func dismiss() {
        presentedMessage = nil
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
