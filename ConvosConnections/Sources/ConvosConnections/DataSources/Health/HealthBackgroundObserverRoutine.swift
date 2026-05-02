import Foundation

/// Long-lived component that:
/// 1. Boots the per-`HealthSampleType` `HKObserverQuery` set on app launch by reading
///    the subscription registry and asking the registrar to observe each unique type.
/// 2. Re-applies the iOS-level background-delivery frequency for each observed type
///    via the manager's aggregation logic.
/// 3. On every observer fire, runs an anchored object query per subscribed conversation
///    starting from the row's saved anchor, emits one `ConnectionPayload` per
///    subscription, and advances the per-row anchor.
///
/// The routine is the only place where deltas are produced. The manager handles the
/// subscribe/unsubscribe wire ops; the routine handles the wake-ups.
///
/// Lifecycle: created once at session boot, started via `start()`. The host app should
/// call `start()` once after the routine is constructed. Subsequent registry mutations
/// (subscribe/unsubscribe) trigger a re-apply via `applyForType(_:)`.
public actor HealthBackgroundObserverRoutine {
    private let store: any HealthBackgroundSubscriptionStore
    private let manager: HealthBackgroundSubscriptionManager
    private let registrar: any HealthBackgroundObserverRegistrar
    private let reader: any HealthDeltaReader
    private let delivery: any ConnectionDelivering
    private let now: @Sendable () -> Date
    private var observedTypes: Set<HealthSampleType> = []
    private var hasStarted: Bool = false

    public init(
        store: any HealthBackgroundSubscriptionStore,
        manager: HealthBackgroundSubscriptionManager,
        registrar: any HealthBackgroundObserverRegistrar,
        reader: any HealthDeltaReader,
        delivery: any ConnectionDelivering,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.manager = manager
        self.registrar = registrar
        self.reader = reader
        self.delivery = delivery
        self.now = now
    }

    /// Boot: read all subscription rows, group by type, register one observer per
    /// unique type, and ask the manager to apply the effective frequency for each.
    /// Idempotent — calling `start()` twice is a no-op.
    public func start() async throws {
        guard !hasStarted else { return }
        hasStarted = true

        let allRows = try await store.allSubscriptions()
        let typesNeedingObserver = Set(allRows.map(\.typeIdentifier))

        for type in typesNeedingObserver {
            try await registerObserver(for: type)
            try await manager.applyEffectiveFrequency(for: type)
        }
    }

    /// Re-evaluate observer registration and iOS frequency for `typeIdentifier`.
    /// Called by the manager after a subscribe/unsubscribe so the routine stays in
    /// sync with the registry without a full restart.
    public func applyForType(_ typeIdentifier: HealthSampleType) async throws {
        let rows = try await store.subscriptions(forType: typeIdentifier)
        if rows.isEmpty {
            await registrar.stop(typeIdentifier: typeIdentifier)
            observedTypes.remove(typeIdentifier)
        } else {
            try await registerObserver(for: typeIdentifier)
        }
        try await manager.applyEffectiveFrequency(for: typeIdentifier)
    }

    /// Visible for testing. Call this directly to simulate iOS waking the host app for
    /// `typeIdentifier`. Pulls deltas for every subscription on that type, delivers a
    /// `ConnectionPayload` per subscription, and advances anchors.
    public func handleObserverFired(typeIdentifier: HealthSampleType) async {
        let rows: [HealthBackgroundSubscription]
        do {
            rows = try await store.subscriptions(forType: typeIdentifier)
        } catch {
            return
        }
        let firedAt = now()
        for row in rows {
            await deliverDelta(for: row, firedAt: firedAt)
        }
    }

    private func registerObserver(for typeIdentifier: HealthSampleType) async throws {
        guard !observedTypes.contains(typeIdentifier) else { return }
        try await registrar.start(typeIdentifier: typeIdentifier) { [weak self] in
            await self?.handleObserverFired(typeIdentifier: typeIdentifier)
        }
        observedTypes.insert(typeIdentifier)
    }

    private func deliverDelta(
        for row: HealthBackgroundSubscription,
        firedAt: Date
    ) async {
        let result: HealthDeltaResult
        do {
            result = try await reader.delta(typeIdentifier: row.typeIdentifier, anchor: row.anchor)
        } catch {
            return
        }
        if result.samples.isEmpty {
            if let anchor = result.anchor {
                try? await store.updateAnchor(
                    conversationId: row.conversationId,
                    agentInboxId: row.agentInboxId,
                    typeIdentifier: row.typeIdentifier,
                    anchor: anchor
                )
            }
            return
        }

        let earliest = result.samples.map(\.startDate).min() ?? firedAt
        let payload = ConnectionPayload(
            source: .health,
            capturedAt: firedAt,
            body: .health(HealthPayload(
                summary: deltaSummary(type: row.typeIdentifier, sampleCount: result.samples.count),
                samples: result.samples,
                rangeStart: earliest,
                rangeEnd: firedAt
            ))
        )

        do {
            try await delivery.deliver(payload, to: row.conversationId)
        } catch {
            return
        }

        if let anchor = result.anchor {
            try? await store.updateAnchor(
                conversationId: row.conversationId,
                agentInboxId: row.agentInboxId,
                typeIdentifier: row.typeIdentifier,
                anchor: anchor
            )
        }
    }

    private func deltaSummary(type: HealthSampleType, sampleCount: Int) -> String {
        let label = type.displayName.lowercased()
        return "\(sampleCount) new \(label) sample\(sampleCount == 1 ? "" : "s")."
    }
}
