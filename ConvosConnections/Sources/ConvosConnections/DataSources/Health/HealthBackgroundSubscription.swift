import Foundation

/// Background-delivery cadence the agent requested when subscribing to a HealthKit
/// object type. iOS may downgrade `immediate` to `hourly` for object types that
/// don't support sub-hourly updates.
public enum HealthBackgroundFrequency: String, Sendable, Codable, CaseIterable, Hashable {
    case immediate
    case hourly
    case daily
    case weekly
}

public extension HealthBackgroundFrequency {
    /// Ordering used to pick the most aggressive frequency among multiple subscribers
    /// on the same `HKObjectType`. Higher rank wins.
    var aggressivenessRank: Int {
        switch self {
        case .immediate: return 4
        case .hourly: return 3
        case .daily: return 2
        case .weekly: return 1
        }
    }
}

/// Persistent subscription row keyed by `(conversationId, agentInboxId, typeIdentifier)`.
///
/// Created when the device handles a `subscribe_background_delivery` invocation; deleted
/// when the device handles `unsubscribe_background_delivery` or when the conversation is
/// torn down (FK cascade). The `anchor` blob is a NSKeyed-archived `HKQueryAnchor`
/// produced by anchored object queries — `nil` until the first delta is delivered.
public struct HealthBackgroundSubscription: Sendable, Hashable {
    public let conversationId: String
    public let agentInboxId: String
    public let typeIdentifier: HealthSampleType
    public let frequency: HealthBackgroundFrequency
    public let historyDays: Int
    public let anchor: Data?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        conversationId: String,
        agentInboxId: String,
        typeIdentifier: HealthSampleType,
        frequency: HealthBackgroundFrequency,
        historyDays: Int,
        anchor: Data? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.conversationId = conversationId
        self.agentInboxId = agentInboxId
        self.typeIdentifier = typeIdentifier
        self.frequency = frequency
        self.historyDays = historyDays
        self.anchor = anchor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
