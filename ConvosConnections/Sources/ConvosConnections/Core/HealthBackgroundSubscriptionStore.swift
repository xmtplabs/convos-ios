import Foundation

/// Persists `HealthBackgroundSubscription` rows. The host app supplies a GRDB-backed
/// implementation; tests and the example app use `InMemoryHealthBackgroundSubscriptionStore`.
///
/// All methods are upsert / point-keyed semantics: writing a subscription replaces any
/// existing row at the same `(conversationId, agentInboxId, typeIdentifier)` key.
public protocol HealthBackgroundSubscriptionStore: Sendable {
    /// Insert or replace a subscription row.
    func upsert(_ subscription: HealthBackgroundSubscription) async throws

    /// Delete a subscription row. No-op if no row exists at the key.
    func delete(
        conversationId: String,
        agentInboxId: String,
        typeIdentifier: HealthSampleType
    ) async throws

    /// Update the observer-query anchor for an existing subscription. No-op if no row
    /// exists at the key. The registrar calls this after each successful delta delivery
    /// to advance the anchor and avoid resending old samples.
    func updateAnchor(
        conversationId: String,
        agentInboxId: String,
        typeIdentifier: HealthSampleType,
        anchor: Data
    ) async throws

    /// All subscriptions across all conversations. Used at boot to register the
    /// per-`HKObjectType` `HKObserverQuery` set.
    func allSubscriptions() async throws -> [HealthBackgroundSubscription]

    /// Subscriptions for a single object type. Used when an observer query fires so the
    /// registrar knows which conversations to fan deltas out to.
    func subscriptions(forType typeIdentifier: HealthSampleType) async throws -> [HealthBackgroundSubscription]

    /// Subscriptions tied to a single conversation. Used for debug surfaces and for
    /// teardown when a conversation is destroyed.
    func subscriptions(forConversation conversationId: String) async throws -> [HealthBackgroundSubscription]
}
