#if canImport(UIKit)
import ConvosCore
import SwiftUI

@Observable
public class MessageContextMenuState: @unchecked Sendable {
    public init() {}

    public var presentedMessage: AnyMessage?
    public var bubbleFrame: CGRect = .zero
    public var isOutgoing: Bool = false
    public var bubbleStyle: MessageBubbleType = .normal
    public var isReplyParent: Bool = false
    public var sourceID: UUID?

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

    public func present(message: AnyMessage, bubbleFrame: CGRect, bubbleStyle: MessageBubbleType) {
        self.isOutgoing = message.sender.isCurrentUser
        self.bubbleFrame = bubbleFrame
        self.bubbleStyle = bubbleStyle
        self.isReplyParent = false
        self.presentedMessage = message
    }

    public func presentReplyParent(message: AnyMessage, bubbleFrame: CGRect, sourceID: UUID) {
        self.isOutgoing = message.sender.isCurrentUser
        self.bubbleFrame = bubbleFrame
        self.bubbleStyle = .normal
        self.isReplyParent = true
        self.sourceID = sourceID
        self.presentedMessage = message
    }

    public func dismiss() {
        presentedMessage = nil
        isReplyParent = false
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
