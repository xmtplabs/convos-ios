import Foundation

/// Owns the subscribe / unsubscribe handlers for HealthKit background delivery.
///
/// Sits behind the `subscribe_background_delivery` and `unsubscribe_background_delivery`
/// actions declared in `HealthActionSchemas`. The host app routes those invocations here
/// from the XMTP listener (because it has the conversationId and senderInboxId that the
/// `DataSink` protocol's `invoke(_:)` doesn't), while every other Health action stays on
/// `HealthDataSink`.
///
/// Two pieces of state live behind the manager:
/// 1. The **subscription registry** (`HealthBackgroundSubscriptionStore`) — durable rows
///    keyed by `(conversationId, agentInboxId, typeIdentifier)`.
/// 2. The **iOS background-delivery setting** for each `HealthSampleType`, mediated by
///    `HealthBackgroundDeliveryGateway`. `HKHealthStore.enableBackgroundDelivery` is
///    global per type, so the manager picks the most aggressive frequency among current
///    subscribers and re-applies it after every subscribe/unsubscribe.
///
/// Backfill emission and observer-query routing are not the manager's responsibility —
/// those run on app launch and on observer wake (steps 4 and 5 in
/// `docs/plans/healthkit-background-subscriptions.md`). The manager only writes
/// registry rows and adjusts the iOS-level setting.
public actor HealthBackgroundSubscriptionManager {
    private let store: any HealthBackgroundSubscriptionStore
    private let gateway: any HealthBackgroundDeliveryGateway
    private let reader: (any HealthBackfillReader)?
    private let delivery: (any ConnectionDelivering)?
    private let now: @Sendable () -> Date

    public init(
        store: any HealthBackgroundSubscriptionStore,
        gateway: any HealthBackgroundDeliveryGateway,
        reader: (any HealthBackfillReader)? = nil,
        delivery: (any ConnectionDelivering)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.gateway = gateway
        self.reader = reader
        self.delivery = delivery
        self.now = now
    }

    /// Handle a `subscribe_background_delivery` invocation. The caller has already
    /// validated that `invocation.action.name` matches the schema name and that the
    /// `.read` capability is enabled for `conversationId`.
    public func handleSubscribe(
        invocation: ConnectionInvocation,
        conversationId: String,
        agentInboxId: String
    ) async -> ConnectionInvocationResult {
        let parsed: SubscribeArguments
        do {
            parsed = try SubscribeArguments.from(invocation.action.arguments)
        } catch let error as ArgumentError {
            return makeResult(for: invocation, status: .executionFailed, errorMessage: error.message)
        } catch {
            return makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
        }

        let subscription = HealthBackgroundSubscription(
            conversationId: conversationId,
            agentInboxId: agentInboxId,
            typeIdentifier: parsed.typeIdentifier,
            frequency: parsed.frequency,
            historyDays: parsed.historyDays
        )

        do {
            try await store.upsert(subscription)
        } catch {
            return makeResult(for: invocation, status: .executionFailed, errorMessage: "Failed to persist subscription: \(error.localizedDescription)")
        }

        let backfill: BackfillOutcome
        do {
            backfill = try await runBackfill(for: subscription)
        } catch {
            return makeResult(
                for: invocation,
                status: .executionFailed,
                errorMessage: "Subscription stored but backfill failed: \(error.localizedDescription)"
            )
        }

        do {
            try await applyEffectiveFrequency(for: parsed.typeIdentifier)
        } catch {
            return makeResult(
                for: invocation,
                status: .executionFailed,
                errorMessage: "Subscription stored but background delivery rejected: \(error.localizedDescription)"
            )
        }

        return makeResult(
            for: invocation,
            status: .success,
            result: [
                "subscriptionId": .string(subscriptionId(for: subscription)),
                "backfillSampleCount": .int(backfill.sampleCount),
            ]
        )
    }

    /// Handle an `unsubscribe_background_delivery` invocation.
    public func handleUnsubscribe(
        invocation: ConnectionInvocation,
        conversationId: String,
        agentInboxId: String
    ) async -> ConnectionInvocationResult {
        let typeIdentifier: HealthSampleType
        do {
            typeIdentifier = try UnsubscribeArguments.from(invocation.action.arguments)
        } catch let error as ArgumentError {
            return makeResult(for: invocation, status: .executionFailed, errorMessage: error.message)
        } catch {
            return makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
        }

        do {
            try await store.delete(
                conversationId: conversationId,
                agentInboxId: agentInboxId,
                typeIdentifier: typeIdentifier
            )
        } catch {
            return makeResult(for: invocation, status: .executionFailed, errorMessage: "Failed to delete subscription: \(error.localizedDescription)")
        }

        do {
            try await applyEffectiveFrequency(for: typeIdentifier)
        } catch {
            return makeResult(
                for: invocation,
                status: .executionFailed,
                errorMessage: "Subscription deleted but background-delivery teardown rejected: \(error.localizedDescription)"
            )
        }

        return makeResult(for: invocation, status: .success)
    }

    /// Run the one-shot backfill query for a freshly-persisted subscription, deliver
    /// the resulting `ConnectionPayload` to the conversation, and persist the anchor
    /// produced by HealthKit.
    ///
    /// Returns a no-op outcome (zero samples, nil anchor) when the manager wasn't
    /// constructed with a reader and delivery — callers can treat backfill as a
    /// best-effort augmentation of subscribe.
    private func runBackfill(
        for subscription: HealthBackgroundSubscription
    ) async throws -> BackfillOutcome {
        guard let reader, let delivery else {
            return BackfillOutcome(sampleCount: 0)
        }
        let endDate = now()
        let startDate = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -subscription.historyDays, to: endDate) ?? endDate
        let result = try await reader.backfill(
            typeIdentifier: subscription.typeIdentifier,
            startDate: startDate,
            endDate: endDate
        )

        let payload = ConnectionPayload(
            source: .health,
            capturedAt: endDate,
            body: .health(HealthPayload(
                summary: backfillSummary(
                    type: subscription.typeIdentifier,
                    sampleCount: result.samples.count,
                    historyDays: subscription.historyDays
                ),
                samples: result.samples,
                rangeStart: startDate,
                rangeEnd: endDate
            ))
        )

        try await delivery.deliver(payload, to: subscription.conversationId)

        if let anchor = result.anchor {
            try await store.updateAnchor(
                conversationId: subscription.conversationId,
                agentInboxId: subscription.agentInboxId,
                typeIdentifier: subscription.typeIdentifier,
                anchor: anchor
            )
        }

        return BackfillOutcome(sampleCount: result.samples.count)
    }

    private func backfillSummary(type: HealthSampleType, sampleCount: Int, historyDays: Int) -> String {
        let label = type.displayName.lowercased()
        if sampleCount == 0 {
            return "No \(label) samples in the last \(historyDays) days."
        }
        return "Backfill: \(sampleCount) \(label) sample\(sampleCount == 1 ? "" : "s") from the last \(historyDays) days."
    }

    private struct BackfillOutcome {
        let sampleCount: Int
    }

    /// Re-evaluate which frequency iOS should be running for `typeIdentifier` based on
    /// the current set of subscribers, and call the gateway to match. Public so the
    /// step-5 observer registrar can reuse it on launch.
    public func applyEffectiveFrequency(for typeIdentifier: HealthSampleType) async throws {
        let rows = try await store.subscriptions(forType: typeIdentifier)
        if let frequency = effectiveFrequency(among: rows) {
            try await gateway.setBackgroundDelivery(typeIdentifier: typeIdentifier, frequency: frequency)
        } else {
            try await gateway.disableBackgroundDelivery(typeIdentifier: typeIdentifier)
        }
    }

    /// Most-aggressive frequency among the rows, or `nil` if there are none.
    /// Visible for testing.
    public nonisolated func effectiveFrequency(
        among rows: [HealthBackgroundSubscription]
    ) -> HealthBackgroundFrequency? {
        rows.map(\.frequency)
            .max(by: { $0.aggressivenessRank < $1.aggressivenessRank })
    }

    private func subscriptionId(for subscription: HealthBackgroundSubscription) -> String {
        "\(subscription.conversationId).\(subscription.agentInboxId).\(subscription.typeIdentifier.rawValue)"
    }

    private func makeResult(
        for invocation: ConnectionInvocation,
        status: ConnectionInvocationResult.Status,
        result: [String: ArgumentValue] = [:],
        errorMessage: String? = nil
    ) -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: invocation.kind,
            actionName: invocation.action.name,
            status: status,
            result: result,
            errorMessage: errorMessage
        )
    }
}

private struct SubscribeArguments {
    let typeIdentifier: HealthSampleType
    let frequency: HealthBackgroundFrequency
    let historyDays: Int

    static func from(_ arguments: [String: ArgumentValue]) throws -> SubscribeArguments {
        let typeRaw = try requireEnum(arguments, key: "typeIdentifier")
        guard let typeIdentifier = HealthSampleType(rawValue: typeRaw) else {
            throw ArgumentError(message: "Unsupported typeIdentifier '\(typeRaw)'.")
        }

        let frequencyRaw = try requireEnum(arguments, key: "frequency")
        guard let frequency = HealthBackgroundFrequency(rawValue: frequencyRaw) else {
            throw ArgumentError(message: "Unsupported frequency '\(frequencyRaw)'.")
        }

        let historyDays = clampHistoryDays(arguments["historyDays"]?.intValue)

        return SubscribeArguments(
            typeIdentifier: typeIdentifier,
            frequency: frequency,
            historyDays: historyDays
        )
    }

    private static func clampHistoryDays(_ raw: Int?) -> Int {
        guard let raw else { return HealthActionSchemas.defaultHistoryDays }
        return min(max(raw, 1), HealthActionSchemas.maxHistoryDays)
    }
}

private enum UnsubscribeArguments {
    static func from(_ arguments: [String: ArgumentValue]) throws -> HealthSampleType {
        let typeRaw = try requireEnum(arguments, key: "typeIdentifier")
        guard let typeIdentifier = HealthSampleType(rawValue: typeRaw) else {
            throw ArgumentError(message: "Unsupported typeIdentifier '\(typeRaw)'.")
        }
        return typeIdentifier
    }
}

private struct ArgumentError: Error {
    let message: String
}

private func requireEnum(_ arguments: [String: ArgumentValue], key: String) throws -> String {
    guard let value = arguments[key] else {
        throw ArgumentError(message: "Missing required argument '\(key)'.")
    }
    if let raw = value.enumRawValue {
        return raw
    }
    if let raw = value.stringValue {
        return raw
    }
    throw ArgumentError(message: "Argument '\(key)' must be a string or enum value.")
}
