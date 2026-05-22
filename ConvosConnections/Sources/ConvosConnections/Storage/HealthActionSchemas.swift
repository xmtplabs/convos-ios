import Foundation

/// Static `ActionSchema` values published by `HealthDataSink`.
///
/// `log_*` actions are mapped to `.writeCreate` since they append a new sample.
/// `fetch_*` and `*_background_delivery` actions are mapped to `.read` so invocation
/// gating uses the conversation's read grant instead of a write verb. Updating or
/// deleting existing samples is out of scope for v1.
///
/// Reads come in two flavors. `fetch_*` is best-effort: the device can only answer
/// when the host app is reachable to run a HealthKit query. `subscribe_background_delivery`
/// is the durable mechanism — the agent declares interest in an object type and iOS
/// drives delivery via an `HKObserverQuery` registered in the host app.
public enum HealthActionSchemas {
    /// HealthKit object-type identifiers we ship support for. The agent supplies one of
    /// these as the `typeIdentifier` argument to subscribe/unsubscribe; the app maps
    /// the raw value back to `HealthSampleType` and then to `HKSampleType`.
    public static let supportedTypeIdentifiers: [String] = HealthSampleType.allCases.map(\.rawValue)

    /// Background-delivery cadences we expose to the agent. iOS may downgrade
    /// `immediate` to `hourly` for object types that don't support it.
    public static let supportedFrequencies: [String] = ["immediate", "hourly", "daily", "weekly"]

    /// Default backfill window for a new subscription, in days.
    public static let defaultHistoryDays: Int = 7

    /// Maximum backfill window the agent may request, in days. Larger windows can stall
    /// the device on the first response and bloat XMTP payloads.
    public static let maxHistoryDays: Int = 90
    public static let logWater: ActionSchema = ActionSchema(
        kind: .health,
        actionName: "log_water",
        capability: .writeCreate,
        summary: "Log a water intake sample (dietary water).",
        inputs: [
            ActionParameter(name: "quantity", type: .double, description: "Volume value.", isRequired: true),
            ActionParameter(name: "unit", type: .enumValue(allowed: ["oz", "mL", "L"]), description: "Volume unit.", isRequired: true),
            ActionParameter(name: "date", type: .iso8601DateTime, description: "Sample time (RFC 3339 with offset). Defaults to now.", isRequired: false),
        ],
        outputs: [
            ActionParameter(name: "sampleId", type: .string, description: "HealthKit sample UUID.", isRequired: true),
        ]
    )

    public static let logCaffeine: ActionSchema = ActionSchema(
        kind: .health,
        actionName: "log_caffeine",
        capability: .writeCreate,
        summary: "Log a caffeine intake sample.",
        inputs: [
            ActionParameter(name: "milligrams", type: .double, description: "Caffeine dose in mg.", isRequired: true),
            ActionParameter(name: "date", type: .iso8601DateTime, description: "Sample time. Defaults to now.", isRequired: false),
        ],
        outputs: [
            ActionParameter(name: "sampleId", type: .string, description: "HealthKit sample UUID.", isRequired: true),
        ]
    )

    public static let logMindfulMinutes: ActionSchema = ActionSchema(
        kind: .health,
        actionName: "log_mindful_minutes",
        capability: .writeCreate,
        summary: "Log a mindful session with a start and end time.",
        inputs: [
            ActionParameter(name: "startDate", type: .iso8601DateTime, description: "Session start (RFC 3339 with offset).", isRequired: true),
            ActionParameter(name: "endDate", type: .iso8601DateTime, description: "Session end (RFC 3339 with offset).", isRequired: true),
        ],
        outputs: [
            ActionParameter(name: "sampleId", type: .string, description: "HealthKit sample UUID.", isRequired: true),
        ]
    )

    public static let fetchSummaryLast24Hours: ActionSchema = ActionSchema(
        kind: .health,
        actionName: "fetch_summary_last_24h",
        capability: .read,
        summary: "Best-effort. Fetch a read-only health summary for the last 24 hours when the host app is reachable. For durable, ongoing data flow, use subscribe_background_delivery.",
        inputs: [],
        outputs: [
            ActionParameter(name: "summary", type: .string, description: "Human-readable summary of the window.", isRequired: true),
            ActionParameter(name: "sampleCount", type: .int, description: "Number of mapped samples in the window.", isRequired: true),
            ActionParameter(name: "rangeStart", type: .iso8601DateTime, description: "Window start (RFC 3339 with offset).", isRequired: true),
            ActionParameter(name: "rangeEnd", type: .iso8601DateTime, description: "Window end (RFC 3339 with offset).", isRequired: true),
            ActionParameter(name: "payloadJson", type: .string, description: "Full HealthPayload JSON string for callers that need richer structured data.", isRequired: true),
        ]
    )

    public static let fetchSamples: ActionSchema = ActionSchema(
        kind: .health,
        actionName: "fetch_samples",
        capability: .read,
        summary: "Best-effort. Fetch read-only health samples for an explicit date range when the host app is reachable. For durable, ongoing data flow, use subscribe_background_delivery.",
        inputs: [
            ActionParameter(name: "startDate", type: .iso8601DateTime, description: "Window start (RFC 3339 with offset).", isRequired: true),
            ActionParameter(name: "endDate", type: .iso8601DateTime, description: "Window end (RFC 3339 with offset). Must be later than startDate.", isRequired: true),
        ],
        outputs: [
            ActionParameter(name: "summary", type: .string, description: "Human-readable summary of the window.", isRequired: true),
            ActionParameter(name: "sampleCount", type: .int, description: "Number of mapped samples in the window.", isRequired: true),
            ActionParameter(name: "rangeStart", type: .iso8601DateTime, description: "Window start (RFC 3339 with offset).", isRequired: true),
            ActionParameter(name: "rangeEnd", type: .iso8601DateTime, description: "Window end (RFC 3339 with offset).", isRequired: true),
            ActionParameter(name: "payloadJson", type: .string, description: "Full HealthPayload JSON string for callers that need richer structured data.", isRequired: true),
        ]
    )

    public static let subscribeBackgroundDelivery: ActionSchema = ActionSchema(
        kind: .health,
        actionName: "subscribe_background_delivery",
        capability: .read,
        summary: """
        Register for ongoing HealthKit deltas of one object type. The first response is a \
        backfill of the last `historyDays` of samples; subsequent deliveries arrive whenever \
        iOS wakes the host app with new data for that type. Each subscription emits its own \
        ConnectionPayload — no batching across types or conversations.
        """,
        inputs: [
            ActionParameter(
                name: "typeIdentifier",
                type: .enumValue(allowed: supportedTypeIdentifiers),
                description: "HealthSampleType identifier to subscribe to (e.g. step_count).",
                isRequired: true
            ),
            ActionParameter(
                name: "frequency",
                type: .enumValue(allowed: supportedFrequencies),
                description: "Background-delivery cadence requested. iOS may deliver less frequently; `immediate` only applies to types that support it.",
                isRequired: true
            ),
            ActionParameter(
                name: "historyDays",
                type: .int,
                description: "Bootstrap window in days (1–\(maxHistoryDays)). Defaults to \(defaultHistoryDays).",
                isRequired: false
            ),
        ],
        outputs: [
            ActionParameter(name: "subscriptionId", type: .string, description: "Stable id for this (conversation × type) subscription.", isRequired: true),
            ActionParameter(name: "backfillSampleCount", type: .int, description: "Number of samples included in the initial backfill payload.", isRequired: true),
        ]
    )

    public static let unsubscribeBackgroundDelivery: ActionSchema = ActionSchema(
        kind: .health,
        actionName: "unsubscribe_background_delivery",
        capability: .read,
        summary: "Stop background deltas for a previously-subscribed object type.",
        inputs: [
            ActionParameter(name: "typeIdentifier", type: .enumValue(allowed: supportedTypeIdentifiers), description: "HealthSampleType identifier to unsubscribe from.", isRequired: true),
        ],
        outputs: []
    )

    public static let all: [ActionSchema] = [
        logWater,
        logCaffeine,
        logMindfulMinutes,
        fetchSummaryLast24Hours,
        fetchSamples,
        subscribeBackgroundDelivery,
        unsubscribeBackgroundDelivery,
    ]
}
