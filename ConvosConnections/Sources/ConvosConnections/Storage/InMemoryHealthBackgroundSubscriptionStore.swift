import Foundation

/// In-memory `HealthBackgroundSubscriptionStore` used by tests, previews, and the
/// example app. The host app supplies a GRDB-backed implementation.
public actor InMemoryHealthBackgroundSubscriptionStore: HealthBackgroundSubscriptionStore {
    private struct Key: Hashable, Sendable {
        let conversationId: String
        let agentInboxId: String
        let typeIdentifier: HealthSampleType
    }

    private var rows: [Key: HealthBackgroundSubscription]

    public init(initial: [HealthBackgroundSubscription] = []) {
        var seeded: [Key: HealthBackgroundSubscription] = [:]
        for subscription in initial {
            let key = Key(
                conversationId: subscription.conversationId,
                agentInboxId: subscription.agentInboxId,
                typeIdentifier: subscription.typeIdentifier
            )
            seeded[key] = subscription
        }
        self.rows = seeded
    }

    public func upsert(_ subscription: HealthBackgroundSubscription) async throws {
        let key = Key(
            conversationId: subscription.conversationId,
            agentInboxId: subscription.agentInboxId,
            typeIdentifier: subscription.typeIdentifier
        )
        rows[key] = subscription
    }

    public func delete(
        conversationId: String,
        agentInboxId: String,
        typeIdentifier: HealthSampleType
    ) async throws {
        let key = Key(
            conversationId: conversationId,
            agentInboxId: agentInboxId,
            typeIdentifier: typeIdentifier
        )
        rows.removeValue(forKey: key)
    }

    public func updateAnchor(
        conversationId: String,
        agentInboxId: String,
        typeIdentifier: HealthSampleType,
        anchor: Data
    ) async throws {
        let key = Key(
            conversationId: conversationId,
            agentInboxId: agentInboxId,
            typeIdentifier: typeIdentifier
        )
        guard let existing = rows[key] else { return }
        rows[key] = HealthBackgroundSubscription(
            conversationId: existing.conversationId,
            agentInboxId: existing.agentInboxId,
            typeIdentifier: existing.typeIdentifier,
            frequency: existing.frequency,
            historyDays: existing.historyDays,
            anchor: anchor,
            createdAt: existing.createdAt,
            updatedAt: Date()
        )
    }

    public func allSubscriptions() async throws -> [HealthBackgroundSubscription] {
        Array(rows.values).sorted(by: Self.deterministicOrder)
    }

    public func subscriptions(forType typeIdentifier: HealthSampleType) async throws -> [HealthBackgroundSubscription] {
        rows.values
            .filter { $0.typeIdentifier == typeIdentifier }
            .sorted(by: Self.deterministicOrder)
    }

    public func subscriptions(forConversation conversationId: String) async throws -> [HealthBackgroundSubscription] {
        rows.values
            .filter { $0.conversationId == conversationId }
            .sorted(by: Self.deterministicOrder)
    }

    private static func deterministicOrder(
        _ lhs: HealthBackgroundSubscription,
        _ rhs: HealthBackgroundSubscription
    ) -> Bool {
        if lhs.conversationId != rhs.conversationId {
            return lhs.conversationId < rhs.conversationId
        }
        if lhs.agentInboxId != rhs.agentInboxId {
            return lhs.agentInboxId < rhs.agentInboxId
        }
        return lhs.typeIdentifier.rawValue < rhs.typeIdentifier.rawValue
    }
}
