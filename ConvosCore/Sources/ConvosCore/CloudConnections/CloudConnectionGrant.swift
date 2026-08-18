import Foundation

public struct CloudConnectionGrant: Codable, Sendable, Hashable {
    public let connectionId: String
    public let conversationId: String
    public let serviceId: String
    /// Inbox id of the agent the grant authorizes. Two agents in the same conversation
    /// have independent grant rows; a grant for one doesn't authorize the other.
    public let grantedToInboxId: String
    public let grantedAt: Date
    /// Permission-bundle ids this grant authorizes (catalog ids like
    /// "calendar.events"). Nil for legacy whole-toolkit grants or services
    /// outside the catalog.
    public let bundleIds: [String]?
    /// Id of the backend ConnectionGrant record created when this grant was
    /// pushed to the server. Nil when the push hasn't happened or failed --
    /// consumers that need a server-confirmed grant (the capability approval
    /// flow) treat a nil id as a push still owed and retry it.
    public let backendGrantId: String?

    public init(
        connectionId: String,
        conversationId: String,
        serviceId: String,
        grantedToInboxId: String,
        grantedAt: Date,
        bundleIds: [String]? = nil,
        backendGrantId: String? = nil
    ) {
        self.connectionId = connectionId
        self.conversationId = conversationId
        self.serviceId = serviceId
        self.grantedToInboxId = grantedToInboxId
        self.grantedAt = grantedAt
        self.bundleIds = bundleIds
        self.backendGrantId = backendGrantId
    }
}
