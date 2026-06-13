import Foundation

/// Conversations that contain an agent provisioned from a given template,
/// split by who added that agent. Drives the agent contact card's "Convos
/// with you" (added by the current user) and "someone else added them"
/// sections. Attribution comes from the agent member's `invitedBy`.
public struct AgentTemplateConversations: Sendable, Equatable {
    public let addedByCurrentUser: [Conversation]
    public let addedByOthers: [Conversation]

    public init(addedByCurrentUser: [Conversation], addedByOthers: [Conversation]) {
        self.addedByCurrentUser = addedByCurrentUser
        self.addedByOthers = addedByOthers
    }

    public static let empty: AgentTemplateConversations = .init(addedByCurrentUser: [], addedByOthers: [])

    public var isEmpty: Bool {
        addedByCurrentUser.isEmpty && addedByOthers.isEmpty
    }
}
